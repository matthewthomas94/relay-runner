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
from codex_model_catalog import CODEX_FAMILIES, normalize_codex_family
from intent_arbitration import explicit_cancel_requested


CONTROL_COMMANDS = {
    "__TTS_STOP__": "tts_stop",
    "__PLAY__": "play",
    "__REPLAY__": "replay",
    "__INTERRUPT__": "interrupt",
    "__CANCEL__": "cancel",
}

TICKET_ID_RE = re.compile(r"\b([A-Za-z][A-Za-z0-9]*-\d+)\b")
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
SCREEN_OBSERVATION_RE = re.compile(
    r"\bwhat(?:'s|\s+is)\s+(?:on\s+)?(?:my|the)\s+(?:screen|display|desktop)\b"
    r"|\b(?:look|check|describe|read)\s+(?:at\s+)?(?:my|the)\s+(?:screen|display|desktop)\b"
    r"|\b(?:take|capture)\s+(?:a\s+)?screenshot\b"
    r"|\bcan\s+you\s+see\b[^.?!]{0,80}\b(?:screen|display|desktop|window)\b",
    re.IGNORECASE,
)
DESKTOP_CONTROL_RE = re.compile(
    r"^\s*(?:please\s+)?(?:open|launch|reveal|bring\s+up|focus|switch\s+to|close|quit)\b"
    r"|\bshow\b[^.?!]{0,80}\b(?:finder|chrome|safari|browser|app|application|folder|directory|file|window)\b"
    r"|^\s*(?:please\s+)?(?:click|double[- ]click|right[- ]click|scroll|press|tap|drag|type|select)\b",
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
RELAY_RUNNER_NAME_RE = re.compile(r"\b(?:the\s+)?relay\s+runner\b", re.IGNORECASE)
RELAY_RUNNER_DEMO_CONTEXT_RE = re.compile(
    r"\b(?:demo(?:ing|nstrat(?:e|ing|ion))?|audience|viewers?)\b",
    re.IGNORECASE,
)
RELAY_RUNNER_EXPLANATION_RE = re.compile(
    r"\b(?:explain|describe|introduce|summari[sz]e)\b[^.?!]{0,160}"
    r"\b(?:what(?:\s+it|\s+what\s+it)+\s+(?:is|does)|"
    r"what\s+(?:the\s+)?relay\s+runner\s+(?:is|does))\b"
    r"|\b(?:explain|describe|introduce|summari[sz]e)\s+"
    r"(?:the\s+)?relay\s+runner\s*(?:[?.!]|$)",
    re.IGNORECASE,
)
RELAY_RUNNER_DIRECT_QUESTION_RE = re.compile(
    r"^\s*(?:(?:hey|hi|okay|ok|so)\b[,!\s]*)*"
    r"(?:what\s+is\s+(?:the\s+)?relay\s+runner\b(?!['’]s\b)"
    r"|what\s+does\s+(?:the\s+)?relay\s+runner\s+do\b)",
    re.IGNORECASE,
)
RELAY_RUNNER_OVERVIEW_RE = re.compile(
    r"\btell\s+(?:me|us|the\s+audience)\s+about\s+(?:the\s+)?relay\s+runner\b"
    r"|\b(?:give|provide)\b[^.?!]{0,80}\b(?:overview|introduction)\b"
    r"[^.?!]{0,80}\b(?:the\s+)?relay\s+runner\b"
    r"|^\s*(?:(?:hey|hi|okay|ok|so)\b[,!\s]*)*what\s+(?:is|are)\s+"
    r"(?:the\s+)?(?:core\s+)?(?:functionality|capabilities|purpose)\s+of\s+"
    r"(?:the\s+)?relay\s+runner\b",
    re.IGNORECASE,
)
_COMMAND_LEAD = r"(?:(?:hey|hi|okay|ok|so|actually|no)\b[,!\s]*)*"
LEADING_TARGET_CONTEXT_RE = re.compile(
    rf"^\s*{_COMMAND_LEAD}(?:"
    r"(?:for|in|on|regarding|about)\s+[^,;:?!]{1,120}"
    r"|[A-Za-z][A-Za-z0-9]*-\d+"
    r")\s*[,;:]\s*(?P<command>.+)$",
    re.IGNORECASE,
)
_MUTATION_VERB = (
    r"(?:add|build|change|clean\s+up|create|debug|delete|design|fix|implement|"
    r"install|make|merge|migrate|refactor|remove|repair|ship|test|wire|write|"
    r"update(?!\s+(?:me|us)\b)|run(?!\s+(?:me|us)\s+through\b))"
)
EXPLICIT_MUTATION_REQUEST_RE = re.compile(
    rf"^\s*{_COMMAND_LEAD}(?:(?:i\s+mean|please|go\s+ahead\s+and)\s+)?(?:"
    rf"{_MUTATION_VERB}\b|(?:do|perform)\s+(?:an?|the)\b)"
    rf"|^\s*{_COMMAND_LEAD}(?:please\s+)?(?:can|could|would|will)\s+"
    rf"you\s+(?:please\s+)?(?:{_MUTATION_VERB}\b|(?:do|perform)\s+(?:an?|the)\b)"
    rf"|^\s*{_COMMAND_LEAD}(?:i|we)\s+(?:need|want|would\s+like)\s+"
    rf"(?:you\s+|us\s+)?to\s+{_MUTATION_VERB}\b"
    rf"|^\s*{_COMMAND_LEAD}(?:i|we)\s+(?:need|want|would\s+like)\s+"
    r"(?:an?\s+)?clean\s+build\b"
    rf"|^\s*{_COMMAND_LEAD}let['’]?s\s+{_MUTATION_VERB}\b",
    re.IGNORECASE,
)
EXPLICIT_DISPATCH_REQUEST_RE = re.compile(
    rf"^\s*{_COMMAND_LEAD}(?:(?:i\s+mean|please)\s+)?"
    r"(?:dispatch|delegate|hand\s+off|kick\s+off|start|spin\s+up|work\s+on|"
    r"run(?!\s+(?:me|us)\s+through\b))\b"
    rf"|^\s*{_COMMAND_LEAD}(?:please\s+)?(?:can|could|would|will)\s+"
    r"you\s+(?:please\s+)?"
    r"(?:dispatch|delegate|hand\s+off|kick\s+off|start|spin\s+up|work\s+on|"
    r"run(?!\s+(?:me|us)\s+through\b))\b",
    re.IGNORECASE,
)
DURABLE_WORK_ESCALATION_RE = re.compile(
    rf"^\s*{_COMMAND_LEAD}(?:(?:please|also)\s+)?(?:queue|track)\b[^.?!]{{0,120}}"
    r"\b(?:analysis|audit|investigation|research|review|spike)\b",
    re.IGNORECASE,
)
WORKER_DELEGATION_RE = re.compile(
    rf"^\s*{_COMMAND_LEAD}(?:(?:i\s+mean|please)\s+)?"
    rf"(?:have|ask|tell)\s+(?:(?:the|a|another)\s+)?(?:worker|agent)\s+"
    rf"(?:to\s+)?(?:{_MUTATION_VERB}|investigate|review)\b",
    re.IGNORECASE,
)
WH_QUESTION_RE = re.compile(
    r"^\s*(?:(?:hey|hi|okay|ok|so|actually|just)\b[,!\s]*)*"
    r"(?:(?:my\s+question\s+is|i\s+(?:wanted|want)\s+to\s+(?:ask|know))\b[:,\s]*)?"
    r"(?:what|which|who|when|where|why|how)\b",
    re.IGNORECASE,
)
AUXILIARY_QUESTION_RE = re.compile(
    r"^\s*(?:(?:hey|hi|okay|ok|so|actually|just)\b[,!\s]*)*"
    r"(?:(?:my\s+question\s+is|i\s+(?:wanted|want)\s+to\s+(?:ask|know))\b[:,\s]*)?"
    r"(?:is|are|am|was|were|do|does|did|has|have|had|should|would|can|could|will)\s+"
    r"(?:i|you|we|they|he|she|it|there|this|that|these|those|the\b)",
    re.IGNORECASE,
)
EPISTEMIC_QUERY_RE = re.compile(
    r"\b(?:can|could|would)\s+you\s+(?:please\s+)?"
    r"(?:check|explain|find\s+out|show|tell)\b"
    r"|\b(?:do|does|did)\s+(?:you|we)\s+know\b"
    r"|\bi(?:'m|\s+am|\s+was)\s+(?:just\s+)?(?:asking|wondering)\b"
    r"|\b(?:my\s+question\s+is|i\s+(?:wanted|want)\s+to\s+know)\b"
    r"|^\s*(?:(?:no|sorry)\b[,!\s]*)*(?:i\s+mean|to\s+clarify|clarification)\b",
    re.IGNORECASE,
)
READ_ONLY_REQUEST_RE = re.compile(
    r"^\s*(?:(?:hey|hi|okay|ok|so|actually|just|please)\b[,!\s]*)*"
    r"(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)?"
    r"(?:update\s+(?:me|us)\b"
    r"|(?:give|provide)\s+(?:me|us)\s+(?:(?:an?|the)\s+)?(?:update|status)\b"
    r"|(?:run|walk)\s+(?:me|us)\s+through\b"
    r"|(?:any|an|the\s+latest)\s+(?:status\s+)?updates?\b)",
    re.IGNORECASE,
)
INFORMATION_IMPERATIVE_RE = re.compile(
    r"^\s*(?:(?:hey|hi|okay|ok|so|actually|just|please)\b[,!\s]*)*"
    r"(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)?"
    r"(?:"
    r"(?:answer|describe|explain|summari[sz]e)\b"
    r"|(?:review|investigate)\b"
    r"|check\s+(?:whether|if|why|how)\b"
    r"|(?:show|tell)\s+(?:me|us)\b"
    r"|(?:find\s+(?:evidence|out)\b|compare\b)"
    r"|(?:check|give|list|present|provide|report|show)\b[^.?!]{0,100}"
    r"\b(?:answer|comparison|details?|differences?|evidence|history|overview|results?|status|summary)\b"
    r")",
    re.IGNORECASE,
)
CONDITIONAL_WORK_RE = re.compile(
    r"\b(?:and|but)\s+(?P<condition>(?:if|unless)\b[^,;.!?]{0,60})\s*,",
    re.IGNORECASE,
)
MIXED_WORK_CLAUSE_RE = re.compile(
    r"(?:\s*[.;]\s*|\s+\b(?:and(?:\s+then)?|but|then)\b\s+)"
    r"(?P<work>(?:please\s+)?(?:add|build|change|clean\s+up|create|debug|delete|"
    r"delegate|design|dispatch|fix|hand\s+off|implement|install|kick\s+off|make|"
    r"merge|migrate|queue|refactor|remove|repair|run|ship|spin\s+up|start|test|track|"
    r"update|wire|work\s+on|write)\b.*)$",
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
        if self.kind == "direct_action":
            return "foreground computer action"
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


def is_relay_runner_self_explanation(text: str) -> bool:
    """Return whether a turn asks for Relay Runner's short product introduction."""
    source = (text or "").strip()
    if not RELAY_RUNNER_NAME_RE.search(source):
        return False
    if (
        RELAY_RUNNER_EXPLANATION_RE.search(source)
        or RELAY_RUNNER_DIRECT_QUESTION_RE.search(source)
        or RELAY_RUNNER_OVERVIEW_RE.search(source)
    ):
        return True
    return bool(
        RELAY_RUNNER_DEMO_CONTEXT_RE.search(source)
        and re.search(r"\b(?:explain|describe|introduce|overview)\b", source, re.IGNORECASE)
    )


def is_information_query(text: str) -> bool:
    """Return whether a turn asks for knowledge without authorizing mutation."""
    source = (text or "").strip()
    if not source:
        return False
    command = _command_clause(source)
    if READ_ONLY_REQUEST_RE.search(source) or READ_ONLY_REQUEST_RE.search(command):
        return True
    if _explicit_project_work_kind(source, _extract_ticket_id(source)) is not None:
        return False
    return bool(
        WH_QUESTION_RE.search(source)
        or WH_QUESTION_RE.search(command)
        or AUXILIARY_QUESTION_RE.search(source)
        or AUXILIARY_QUESTION_RE.search(command)
        or EPISTEMIC_QUERY_RE.search(source)
        or EPISTEMIC_QUERY_RE.search(command)
        or INFORMATION_IMPERATIVE_RE.search(source)
        or INFORMATION_IMPERATIVE_RE.search(command)
    )


def _command_clause(source: str) -> str:
    """Return the operative clause after a punctuated leading target context."""
    match = LEADING_TARGET_CONTEXT_RE.search(source)
    return match.group("command").strip() if match else source


def _explicit_project_work_kind(source: str, ticket_id: str | None) -> str | None:
    """Return the mutation route authorized by command grammar, if any."""
    command = _command_clause(source)
    if DURABLE_WORK_ESCALATION_RE.search(command):
        return "create_ticket"
    if WORKER_DELEGATION_RE.search(command) or EXPLICIT_DISPATCH_REQUEST_RE.search(command):
        return "dispatch_ticket" if ticket_id else "create_ticket"
    if EXPLICIT_MUTATION_REQUEST_RE.search(command):
        return "update_ticket" if ticket_id else "create_ticket"
    return None


def is_mixed_query_and_mutation(text: str) -> bool:
    """Detect a mutation clause attached to a read-only query."""
    source = (text or "").strip()
    for match in CONDITIONAL_WORK_RE.finditer(source):
        query_clause = source[:match.start()].rstrip(" ,")
        work_clause = source[match.end():].lstrip(" ,")
        if is_information_query(query_clause) and _explicit_project_work_kind(
            work_clause,
            _extract_ticket_id(work_clause),
        ) is not None:
            return True
    match = MIXED_WORK_CLAUSE_RE.search(source)
    if match:
        query_clause = source[:match.start()].rstrip(" ,")
        work_clause = match.group("work")
        if is_information_query(query_clause) and _explicit_project_work_kind(
            work_clause,
            _extract_ticket_id(work_clause),
        ) is not None:
            return True
    return False


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

    if explicit_cancel_requested(source):
        return CommandAction(kind="control", source_text=source, reason="cancel")

    if SCREEN_OBSERVATION_RE.search(source):
        return CommandAction(
            kind="direct_action",
            source_text=source,
            reason="screen_observation",
        )

    if DESKTOP_CONTROL_RE.search(source):
        return CommandAction(
            kind="direct_action",
            source_text=source,
            reason="desktop_control",
        )

    if is_relay_runner_self_explanation(source):
        return CommandAction(
            kind="conversation",
            source_text=source,
            reason="relay_runner_self_explanation",
        )

    if INLINE_RE.search(source):
        return CommandAction(kind="inline_work", source_text=source)

    if PENDING_WORK_RE.search(source):
        return CommandAction(kind="control", source_text=source, reason="pending_work_instruction")

    ticket_id = _extract_ticket_id(source)
    project_work_kind = _explicit_project_work_kind(source, ticket_id)
    if project_work_kind is not None:
        if SESSION_OPERATION_RE.search(source):
            return CommandAction(kind="inline_work", source_text=source)
        return CommandAction(
            kind=project_work_kind,
            source_text=source,
            requires_ticket=True,
            ticket_id=ticket_id if project_work_kind != "create_ticket" else None,
        )

    if is_mixed_query_and_mutation(source):
        return CommandAction(
            kind="conversation",
            source_text=source,
            reason="mixed_query_and_mutation_clarification",
        )

    information_query = is_information_query(source)

    if SESSION_OPERATION_RE.search(source) and not information_query:
        return CommandAction(kind="inline_work", source_text=source)

    if information_query:
        if ticket_id:
            return CommandAction(
                kind="inspect_ticket",
                source_text=source,
                requires_ticket=False,
                ticket_id=ticket_id,
                reason="information_query",
            )
        return CommandAction(
            kind="conversation",
            source_text=source,
            reason="information_query",
        )

    if ticket_id:
        return CommandAction(
            kind="inspect_ticket",
            source_text=source,
            requires_ticket=False,
            ticket_id=ticket_id,
            reason="ticket_inspection" if INSPECT_RE.search(source) else "ticket_reference",
        )

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


def format_command_for_agent(action: CommandAction, disposition: dict | None = None) -> str:
    if action.kind in {"conversation", "control"}:
        prompt = action.source_text
        if action.reason == "mixed_query_and_mutation_clarification":
            prompt = (
                f"{prompt}\n\n"
                "Relay Runner command action:\n"
                "- action: conversation\n"
                "- mutation_authorized: false\n"
                "- Ask one concise clarification before creating, editing, or dispatching any ticket. "
                "The information query may be answered, but its conditional work clause is not "
                "durable mutation authority."
            )
        return _append_work_disposition(prompt, disposition)

    if action.kind == "direct_action":
        lines = [
            action.source_text,
            "",
            "Relay Runner command action:",
            "- action: direct_action",
            "- ticket_id: null",
            "- outcome_to_report: foreground computer action",
            f"- reason: {action.reason}",
        ]
        if action.repo_path:
            lines.append(f"- repo_path: {action.repo_path}")
        lines.extend(_relay_prompt_lines(action).splitlines())
        lines.extend([
            "",
            "Foreground computer-action contract:",
            "- Handle this directly in the foreground PM. Do not create a ticket, dispatch a worker, or send this to the Relay daemon.",
            "- The messenger remains tool-free; it may acknowledge and speak the PM's final result, but it never executes the action.",
            "- Prefer a deterministic shell or operating-system command when it can fully complete the request, including launching an app, opening or revealing a known path, or locating a file.",
            "- Do not inspect the screen merely to navigate toward an action that a direct command can complete.",
            "- Use Relay Vision when the request genuinely requires observing pixels or visible UI state.",
            "- Use Relay Actions only when visual interaction is necessary after direct-command options are exhausted. Never use native computer-use tools while the Relay stack is connected.",
            "- Check that this Relay command is still current immediately before every side effect. Ask in normal chat before a genuinely high-stakes or irreversible action.",
            "- Report the completed action or exact blocker concisely through the normal authoritative reply path so the messenger can speak it.",
        ])
        return _append_work_disposition("\n".join(lines), disposition)

    if action.kind == "inline_work":
        metadata = _relay_prompt_lines(action)
        prompt = (
            f"{action.source_text}\n\n"
            "Relay Runner command action:\n"
            "- action: inline_work\n"
            "- ticket_id: null\n"
            "- outcome_to_report: inline work explicitly requested\n"
            f"{metadata}"
        )
        return _append_work_disposition(prompt, disposition)

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
            "- Relay command metadata has two provider-neutral checks: newest-turn freshness gates user-visible replies, traces, and TTS; mutation authorization gates ticket edits, dispatches, and orchestrator actions.",
            "- Before any user-visible follow-up, trace, or TTS, verify this command is still current; if a newer command exists, stop the stale output and let Relay Runner deliver the newer turn.",
            "- Before any ticket edit, dispatch, or orchestrator action, pass relay_command_seq and relay_command_id. The daemon allows an older command only when Relay Runner registered that bounded mutation authorization and no replacement, redirect, interrupt, or cancel turn has revoked it. Acknowledgement, inspection/status, and additive turns do not revoke prior authorized mutations.",
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
        lines.append("- No ticket was created because no active Workspace project was found; ask the user which repo/project should own the work.")

    lines.extend(["", "Source command:", action.source_text])
    return _append_work_disposition("\n".join(lines), disposition)


def _append_work_disposition(prompt: str, disposition: dict | None) -> str:
    if not isinstance(disposition, dict):
        return prompt
    route = str(disposition.get("route") or "").strip()
    if not route:
        return prompt
    targets = ", ".join(str(value) for value in disposition.get("target_work_ids") or []) or "none"
    conflicts = ", ".join(str(value) for value in disposition.get("conflicting_work_ids") or []) or "none"
    question = str(disposition.get("clarification_question") or "").strip()
    lines = [
        prompt,
        "",
        "Relay work-intent disposition:",
        f"- route: {route}",
        f"- target_work_ids: {targets}",
        f"- conflicting_work_ids: {conflicts}",
        f"- mutation_authorization_effect: {disposition.get('authorization_effect') or 'preserve'}",
        f"- public_reason: {disposition.get('public_reason') or 'Resolved by the bridge policy.'}",
        "- Treat this as the provider-neutral relationship to already accepted work.",
        "- Do not preempt accepted work unless this route is replace_current.",
        "- queue_project_work stays on the native Relay ticket/worktree path.",
        "- run_sidecar is read-only, bounded, independently verifiable, resource-safe, and never speaks directly.",
    ]
    if question:
        lines.append(f"- clarification_question: {question}")
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

    provider = _normalized_general_provider(general.get("provider") or general.get("command"))
    model = _normalized_general_model(general.get("model"), provider)
    effort = _normalized_general_effort(
        general.get("orchestrator_effort") or general.get("codex_reasoning_effort"),
        provider,
        model,
    )
    return (
        f"worker_model: {provider}:{model}\n"
        f"worker_effort: {effort}\n"
        "worker_sizing_rationale: \"Inherited provider, model, and effort from Relay Runner General Settings.\"\n"
        "worker_provider_notes: \"Use my defaults preserves explicit stable provider selections; Codex resolves Sol/Terra/Luna then uses model_reasoning_effort and Claude uses --effort.\"\n"
    )


def _normalized_general_provider(value: object) -> str:
    text = str(value or "").strip().lower()
    return "claude" if "claude" in text else "codex"


def _normalized_general_model(value: object, provider: str) -> str:
    model = str(value or "").strip().lower()
    if provider == "codex":
        return normalize_codex_family(model)
    valid_models = {
        "codex": CODEX_FAMILIES,
        "claude": {"fable", "opus", "sonnet", "haiku"},
    }
    return model if model in valid_models[provider] else "opus"


def _valid_general_efforts(provider: str, model: str) -> set[str]:
    base = {"low", "medium", "high", "xhigh"}
    if provider == "codex":
        return base | {"max", "ultra"}
    if model in {"fable", "opus"}:
        return base | {"max"}
    if model == "sonnet":
        return {"low", "medium", "high", "max"}
    return {"low"}


def _normalized_general_effort(value: object, provider: str, model: str) -> str:
    effort = str(value or "").strip().lower()
    if effort == "default":
        effort = "xhigh"
    if effort in _valid_general_efforts(provider, model):
        return effort
    return "xhigh" if "xhigh" in _valid_general_efforts(provider, model) else "low"
