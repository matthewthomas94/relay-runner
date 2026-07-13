"""Relay command action classification.

The foreground Codex or Claude session is the PM frontstage. This module keeps
voice/text command handling explicit before work routes backstage: controls are
intentional no-ticket actions, ticket references attach to existing work, and
new project-work requests become refined management tickets before any worker
implementation starts. Raw Relay captures stay private; visible ticket prose is
actionable summary, not transcript dump.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re

from config import load_config


CONTROL_COMMANDS = {
    "__TTS_STOP__": "tts_stop",
    "__PLAY__": "play",
    "__REPLAY__": "replay",
    "__INTERRUPT__": "interrupt",
    "__CANCEL__": "cancel",
}

TICKET_ID_RE = re.compile(r"\b([A-Za-z][A-Za-z0-9]*-\d+)\b")
DISPATCH_RE = re.compile(
    r"\b(dispatch|delegate|hand\s+off|kick\s+off|start|run|spin\s+up|work\s+on)\b",
    re.IGNORECASE,
)
INSPECT_RE = re.compile(
    r"\b(status|state|how'?s|how\s+is|what'?s|what\s+is|show|summarize|check)\b",
    re.IGNORECASE,
)
INLINE_RE = re.compile(
    r"\b(inline|in\s+this\s+session|do\s+it\s+here|don'?t\s+dispatch|without\s+(a\s+)?ticket)\b",
    re.IGNORECASE,
)
SESSION_OPERATION_RE = re.compile(
    r"\b(?:rebuild|build)\b[^.?!]{0,80}\binstall\b"
    r"|\bcommit\b[^.?!]{0,80}\b(?:remote|push|everything|all\s+changes|changes)\b"
    r"|\bpush\b[^.?!]{0,80}\b(?:remote|origin|main)\b",
    re.IGNORECASE,
)
PENDING_WORK_RE = re.compile(
    r"\b(?:once|when|after)\s+"
    r"(?:(?:all|any|the|these|those|this|that)\s+)?"
    r"(?:[A-Za-z][A-Za-z0-9]*-\d+|ticket|tickets|run|runs|worker|workers|it|they|these|those)\b"
    r"[^.?!]*\b(done|finish|finished|complete|completed|merge|merged|review|reviewed)\b",
    re.IGNORECASE,
)
ORCHESTRATION_CORRECTION_RE = re.compile(
    r"\bwhy\s+did\s+you\s+(?:write|create|make|dispatch)\b.*\b(ticket|orchestrator)\b"
    r"|\bthe\s+(?:entire\s+)?point\s+is\b.*\borchestrator\b.*\b(?:write|create|author)\b.*\bticket\b"
    r"|\bso\s+(?:i|we)\s+can\s+continue\s+talking\b.*\b(ticket|orchestrator)\b",
    re.IGNORECASE,
)
WORK_RE = re.compile(
    r"\b(add|build|change|clean\s+up|create|debug|delete|design|fix|implement|"
    r"install|make|migrate|refactor|remove|repair|ship|test|update|wire|write)\b",
    re.IGNORECASE,
)
PREFIX_RE = re.compile(r'^\s*prefix\s*=\s*["\']?([A-Za-z][A-Za-z0-9]*)["\']?\s*$', re.MULTILINE)
NEXT_ID_RE = re.compile(r"^(\s*next_id\s*=\s*)(\d+)(\s*)$", re.MULTILINE)
SUMMARY_TOKEN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")
SUMMARY_VERBS = {
    "add": "Add",
    "build": "Build",
    "change": "Update",
    "clean": "Clean up",
    "create": "Create",
    "debug": "Debug",
    "delete": "Remove",
    "design": "Design",
    "fix": "Fix",
    "implement": "Implement",
    "install": "Install",
    "make": "Implement",
    "migrate": "Migrate",
    "refactor": "Refactor",
    "remove": "Remove",
    "repair": "Repair",
    "ship": "Ship",
    "test": "Test",
    "update": "Update",
    "wire": "Wire",
    "write": "Write",
}
SUMMARY_STOP_WORDS = {
    "a",
    "an",
    "and",
    "are",
    "as",
    "can",
    "could",
    "for",
    "from",
    "i",
    "in",
    "into",
    "it",
    "let",
    "lets",
    "me",
    "my",
    "of",
    "on",
    "our",
    "please",
    "that",
    "the",
    "this",
    "to",
    "we",
    "with",
    "you",
}
SUMMARY_PRIVATE_WORDS = {
    "api",
    "credential",
    "credentials",
    "key",
    "passcode",
    "password",
    "private",
    "secret",
    "source_text",
    "token",
    "transcript",
}


@dataclass(frozen=True)
class CommandAction:
    kind: str
    source_text: str
    requires_ticket: bool = False
    ticket_id: str | None = None
    ticket_path: str | None = None
    repo_path: str | None = None
    reason: str = ""
    relay_command_id: str | None = None
    relay_command_seq: int | None = None

    @property
    def outcome(self) -> str:
        if self.kind == "create_ticket" and self.ticket_id:
            return f"created ticket {self.ticket_id}"
        if self.kind == "create_ticket":
            return "project work needs refined ticket"
        if self.kind == "dispatch_ticket" and self.ticket_id:
            return f"dispatch ticket {self.ticket_id}"
        if self.kind == "update_ticket" and self.ticket_id:
            return f"edit ticket {self.ticket_id}"
        if self.kind == "inspect_ticket" and self.ticket_id:
            return f"inspect ticket {self.ticket_id}"
        if self.kind == "inline_work":
            return "inline work explicitly requested"
        if self.kind == "needs_project":
            return "waiting on target-project choice"
        if self.kind == "control":
            return f"control action {self.reason}"
        return "normal conversation"


def is_control_command(text: str) -> bool:
    value = (text or "").strip()
    return (
        value in CONTROL_COMMANDS
        or value.startswith("__STATUS__:")
        or value.startswith("__TRACE__:")
        or value.startswith("__ORCHESTRATOR_REPLY__:")
    )


def classify_command(text: str) -> CommandAction:
    source = (text or "").strip()
    if is_control_command(source):
        reason = CONTROL_COMMANDS.get(source)
        if reason is None:
            if source.startswith("__TRACE__:"):
                reason = "trace"
            elif source.startswith("__ORCHESTRATOR_REPLY__:"):
                reason = "orchestrator_reply"
            else:
                reason = "status"
        return CommandAction(kind="control", source_text=source, reason=reason)

    if ORCHESTRATION_CORRECTION_RE.search(source):
        return CommandAction(kind="control", source_text=source, reason="orchestration_process_correction")

    if INLINE_RE.search(source):
        return CommandAction(kind="inline_work", source_text=source)

    if PENDING_WORK_RE.search(source):
        return CommandAction(kind="control", source_text=source, reason="pending_work_instruction")

    if SESSION_OPERATION_RE.search(source):
        return CommandAction(kind="inline_work", source_text=source)

    ticket_id = _extract_ticket_id(source)
    if ticket_id:
        if DISPATCH_RE.search(source):
            return CommandAction(
                kind="dispatch_ticket",
                source_text=source,
                requires_ticket=True,
                ticket_id=ticket_id,
            )
        if INSPECT_RE.search(source):
            return CommandAction(
                kind="inspect_ticket",
                source_text=source,
                requires_ticket=True,
                ticket_id=ticket_id,
            )
        return CommandAction(
            kind="update_ticket",
            source_text=source,
            requires_ticket=True,
            ticket_id=ticket_id,
        )

    if WORK_RE.search(source):
        return CommandAction(kind="create_ticket", source_text=source, requires_ticket=True)

    return CommandAction(kind="conversation", source_text=source)


def resolve_command_action(
    text: str,
    repo_path: str | Path | None = None,
    relay_command: dict | None = None,
) -> CommandAction:
    action = classify_command(text)
    if action.kind != "create_ticket":
        return _with_relay(_with_repo(action, repo_path), relay_command)

    repo = Path(repo_path or Path.cwd()).expanduser().resolve()
    return CommandAction(
        kind="create_ticket",
        source_text=action.source_text,
        requires_ticket=True,
        repo_path=str(repo),
        reason="project work needs a refined visible ticket before dispatch; keep raw Relay transcript private",
        **_relay_fields(relay_command),
    )


def create_ticket_for_command(
    repo_path: str | Path,
    source_text: str,
    relay_command: dict | None = None,
    general_config: dict | None = None,
) -> tuple[str, Path]:
    repo = Path(repo_path).expanduser().resolve()
    orch_dir = repo / ".orchestrator"
    config_path = orch_dir / "config.toml"
    config_text = config_path.read_text()
    prefix, next_id = _read_ticket_config(config_text)

    ticket_number = next_id
    while True:
        ticket_id = f"{prefix}-{ticket_number}"
        ticket_path = orch_dir / f"{ticket_id}.md"
        if not ticket_path.exists():
            break
        ticket_number += 1

    ticket_path.write_text(
        _ticket_body(
            ticket_id,
            source_text,
            relay_command=relay_command,
            general_config=general_config,
        )
    )
    _write_next_id(config_path, config_text, ticket_number + 1)
    return ticket_id, ticket_path


def refined_command_summary(source_text: str) -> str:
    """Return a short, user-safe summary without copying the raw command."""
    tokens = [token.lower() for token in SUMMARY_TOKEN_RE.findall(source_text or "")]
    verb = "Implement"
    verb_index = -1
    for index, token in enumerate(tokens):
        if token in SUMMARY_VERBS:
            verb = SUMMARY_VERBS[token]
            verb_index = index
            break

    subject_tokens: list[str] = []
    for token in tokens[verb_index + 1 if verb_index >= 0 else 0:]:
        if token in SUMMARY_VERBS or token in SUMMARY_STOP_WORDS or token in SUMMARY_PRIVATE_WORDS:
            continue
        if re.fullmatch(r"[a-z][a-z0-9]*-\d+", token):
            continue
        subject_tokens.append(token.replace("_", "-"))
        if len(subject_tokens) >= 6:
            break

    subject = " ".join(subject_tokens).strip()
    if not subject:
        subject = "requested project change"
    return f"{verb} {subject}."


def refined_ticket_title(source_text: str) -> str:
    title = refined_command_summary(source_text).rstrip(".")
    if len(title) > 76:
        title = title[:73].rstrip() + "..."
    return title


def format_command_for_agent(action: CommandAction) -> str:
    if action.kind in {"conversation", "control"}:
        return action.source_text

    if action.kind == "inline_work":
        metadata = _relay_prompt_lines(action)
        return (
            f"{action.source_text}\n\n"
            "Relay Runner command action:\n"
            "- action: inline_work\n"
            "- ticket_id: null\n"
            "- outcome_to_report: inline work explicitly requested\n"
            f"{metadata}"
        )

    lines = [
        "Relay Runner command action:",
        f"- action: {action.kind}",
        f"- ticket_id: {action.ticket_id or 'null'}",
        f"- outcome_to_report: {action.outcome}",
    ]
    if action.ticket_path:
        lines.append(f"- ticket_path: {action.ticket_path}")
    if action.repo_path:
        lines.append(f"- repo_path: {action.repo_path}")
    if action.reason:
        lines.append(f"- reason: {action.reason}")
    lines.extend(_relay_prompt_lines(action).splitlines())

    lines.extend(
        [
            "",
            "PM frontstage contract:",
            "- You are the PM frontstage for the user, not the implementation worker.",
            "- Keep the user-facing response concise and status-oriented; do not perform substantive source-code implementation directly unless the source command explicitly asks for inline work.",
            "- The foreground orchestrator/PM owns command classification and visible-ticket authoring for new raw work requests.",
            "- Raw Relay command captures are private metadata, not board cards; visible `.orchestrator/` tickets must use refined, user-safe summaries and acceptance criteria instead of transcript dumps.",
            "- Creating or editing visible `.orchestrator/` tickets is PM management work. Implementation belongs to workers unless the user explicitly asks to keep it inline.",
            "- Relay command metadata is the stale-action guard. Before any user-visible follow-up, TTS, ticket edit, dispatch, or orchestrator action, verify this command is still current; if a newer command exists, stop this stale action and handle the newer command.",
            "- When a later dispatch request goes through relay-orchestrator, pass relay_command_seq and relay_command_id when they are present.",
            "- Your user-facing response must name the PM outcome, such as created ticket, edited ticket, dispatched worker, waiting on refined ticket content, or waiting on a target-project choice.",
        ]
    )

    if action.kind == "create_ticket":
        lines.append("- Create or refine a visible ticket now if the target project and scope are clear; otherwise ask one concise clarification. Do not implement the ticket yourself.")
    elif action.kind == "dispatch_ticket":
        lines.append("- Dispatch the named ticket through relay-orchestrator; do not implement the ticket yourself.")
    elif action.kind == "update_ticket":
        lines.append("- Edit/refine the named ticket so it can survive a cold worker run; dispatch only after it is ready.")
    elif action.kind == "inspect_ticket":
        lines.append("- Inspect/report ticket or run state; do not implement the ticket yourself.")
    elif action.kind == "needs_project":
        lines.append("- No ticket was created because no active project board was found; ask the user which repo/project should own the work.")

    lines.extend(["", "Source command:", action.source_text])
    return "\n".join(lines)


def _with_repo(action: CommandAction, repo_path: str | Path | None) -> CommandAction:
    if repo_path is None:
        return action
    data = dict(action.__dict__)
    data["repo_path"] = str(Path(repo_path).expanduser().resolve())
    return CommandAction(**data)


def _with_relay(action: CommandAction, relay_command: dict | None) -> CommandAction:
    fields = _relay_fields(relay_command)
    if not fields:
        return action
    data = dict(action.__dict__)
    data.update(fields)
    return CommandAction(**data)


def _relay_fields(relay_command: dict | None) -> dict:
    if not relay_command:
        return {}
    result: dict = {}
    command_id = relay_command.get("relay_command_id")
    command_seq = relay_command.get("relay_command_seq")
    if command_id:
        result["relay_command_id"] = str(command_id)
    if command_seq is not None:
        try:
            result["relay_command_seq"] = int(command_seq)
        except (TypeError, ValueError):
            pass
    return result


def _relay_prompt_lines(action: CommandAction) -> str:
    lines = []
    if action.relay_command_seq is not None:
        lines.append(f"- relay_command_seq: {action.relay_command_seq}")
    if action.relay_command_id:
        lines.append(f"- relay_command_id: {action.relay_command_id}")
    if not lines:
        return ""
    return "\n".join(lines) + "\n"


def _extract_ticket_id(text: str) -> str | None:
    match = TICKET_ID_RE.search(text or "")
    return match.group(1).upper() if match else None


def _read_ticket_config(config_text: str) -> tuple[str, int]:
    prefix_match = PREFIX_RE.search(config_text)
    next_match = NEXT_ID_RE.search(config_text)
    if not prefix_match or not next_match:
        raise ValueError("invalid .orchestrator/config.toml: expected prefix and next_id")
    return prefix_match.group(1).upper(), int(next_match.group(2))


def _write_next_id(config_path: Path, config_text: str, next_id: int) -> None:
    if NEXT_ID_RE.search(config_text):
        updated = NEXT_ID_RE.sub(lambda m: f"{m.group(1)}{next_id}{m.group(3)}", config_text, count=1)
    else:
        updated = config_text.rstrip() + f"\nnext_id = {next_id}\n"
    config_path.write_text(updated if updated.endswith("\n") else updated + "\n")


def _ticket_body(
    ticket_id: str,
    source_text: str,
    relay_command: dict | None = None,
    general_config: dict | None = None,
) -> str:
    title = refined_ticket_title(source_text)
    summary = refined_command_summary(source_text)
    return (
        "---\n"
        f"id: {ticket_id}\n"
        f"title: {title}\n"
        "status: backlog\n"
        "priority: medium\n"
        "depends_on: []\n"
            "run_id: null\n"
            "canceled: false\n"
            f"{_worker_sizing_frontmatter(general_config)}"
            "---\n\n"
        "## Description\n\n"
        "The foreground orchestrator/PM prepared this refined project-work ticket.\n\n"
        f"Summary: {summary}\n\n"
        "Use the repository context to identify the exact implementation path. "
        "Raw Relay transcript text remains private orchestrator metadata.\n\n"
        "## Acceptance criteria\n\n"
        "- [ ] The ticket contains enough context for a worker to complete the change in one pass.\n"
        "- [ ] Implementation work is dispatched to a worker, unless the user explicitly asks to keep it inline.\n"
    )


def _worker_sizing_frontmatter(general_config: dict | None = None) -> str:
    general = general_config
    if general is None:
        try:
            general = load_config().get("general", {})
        except Exception:  # noqa: BLE001 - ticket creation must not fail on unreadable Settings.
            general = {}
    if general.get("subagent_sizing_policy") != "user_default":
        return ""

    model = _normalized_subagent_model(general.get("subagent_model"))
    effort = _normalized_subagent_effort(general.get("subagent_effort"))
    return (
        f"worker_model: {model}\n"
        f"worker_effort: {effort}\n"
        "worker_sizing_rationale: \"User default from Relay Runner Settings.\"\n"
        "worker_provider_notes: \"User default applies to Codex and Claude; Codex uses model_reasoning_effort and Claude uses --effort.\"\n"
    )


def _normalized_subagent_model(value: object) -> str:
    model = str(value or "").strip().lower()
    return model if model in {"fast", "balanced", "strong"} else "balanced"


def _normalized_subagent_effort(value: object) -> str:
    effort = str(value or "").strip().lower()
    return effort if effort in {"low", "medium", "high", "xhigh"} else "medium"
