#!/usr/bin/env python3
"""Relay-runner orchestrator daemon.

Symphony-style sub-agent orchestrator: dispatches tickets from a repo's local
kanban board (`<repo>/.orchestrator/<ticket_id>.md`) to autonomous Codex or
Claude runs in isolated worktrees, and tracks state in SQLite. HTTP API on 127.0.0.1;
MCP tool surface is the thin Swift proxy in Sources/relay-orchestrator-mcp/
which calls these endpoints.

MVP scope: voice/MCP-driven dispatch only. The repo is the source of truth —
tickets live as version-controlled markdown under `.orchestrator/`, and the
sub-agent edits its ticket's YAML frontmatter + appends a "## Run log" section
when it finishes. No external service is involved.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import tomllib
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse

# Reuse the existing config loader (sibling file).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import load_config
try:
    from services.artifact_lifecycle import ArtifactLifecycleCoordinator
    from services.artifact_store import ArtifactStore, ArtifactValidationError
except ModuleNotFoundError:  # Installed direct-script layout.
    from artifact_lifecycle import ArtifactLifecycleCoordinator  # type: ignore[no-redef]
    from artifact_store import ArtifactStore, ArtifactValidationError  # type: ignore[no-redef]
from command_actions import refined_command_summary, refined_ticket_title, resolve_command_action
from codex_model_catalog import (
    CODEX_FAMILIES,
    CODEX_WORKER_TIER_FAMILIES,
    CodexModelResolutionError,
    normalize_codex_family,
    resolve_codex_effort,
    resolve_codex_family_from_cli,
)
from graphify_core import GraphifyCoreStore
from graphify_ingest import ingest_registered_projects
from followup_tickets import (
    FOLLOWUP_KEY_PREFIX,
    FollowupProposalStore,
    acceptance_key as followup_acceptance_key,
    automatic_followup_drafts,
    sanitize_followup_draft,
)
from pm_frontstage import OrchestrationTraceEvent, PMStatusEvent, RelayCommandMetadata
from program_status import build_program_dashboard, build_program_status
from relay_authorization import (
    authorization_exists,
    mark_mutations_canceled,
    validate_and_mark_mutation,
)
from session_capture import capture_session_review
from tickets import (
    TicketParseError,
    read as read_ticket,
    scan_repo,
    write as write_ticket,
    all_deps_done,
)

PORT_FILE = Path("/tmp/relay_orchestrator.port")
RELAY_COMMAND_STATE_FILE = Path("/tmp/voice_command_state.json")
RELAY_COMMAND_AUTHORIZATION_FILE = Path("/tmp/voice_command_authorizations.json")
VOICE_STATE_SOCK = Path("/tmp/voice_state.sock")
DEFAULT_PORT = 7634
ORCHESTRATOR_SESSION_STATES = frozenset({
    "idle",
    "planning",
    "awaiting_workers",
    "reviewing",
    "blocked",
    "failed",
    "stopped",
    "stale",
})
ORCHESTRATOR_SESSION_STALE_AFTER_SECONDS = 30.0
ORCHESTRATOR_COMMAND_STATUSES = frozenset({
    "received",
    "classified",
    "queued",
    "claimed",
    "mutation_authorized",
    "planning",
    "authored",
    "created",
    "updated",
    "dispatched",
    "clarification_required",
    "superseded",
    "rejected",
    "delivery_failed",
    "blocked",
    "handled",
    "stale",
    "failed",
})
ORCHESTRATOR_COMMAND_TERMINAL_STATUSES = frozenset({
    "authored",
    "created",
    "updated",
    "dispatched",
    "clarification_required",
    "superseded",
    "rejected",
    "delivery_failed",
    "blocked",
    "handled",
    "stale",
    "failed",
})

WORKER_SIZING_FIELDS = (
    "worker_model",
    "worker_effort",
    "worker_sizing_rationale",
    "worker_provider_notes",
)
EXECUTION_MODES = frozenset({"implementation", "spike"})
SPIKE_EXECUTION_MODE = "spike"
SPIKE_COMPLETED_RUN_STATE = "SpikeCompleted"
VERIFICATION_BLOCKED_STATUS = "verification_blocked"
VERIFICATION_BLOCKED_RUN_STATE = "VerificationBlocked"
VERIFICATION_BLOCKER_FIELDS = ("verification_blocker", "verification_resume")
REVIEW_BLOCKING_STATES = ("AwaitingReview", "Reviewing", "MergeConflict", "Succeeded")
MERGEABLE_REVIEW_STATES = REVIEW_BLOCKING_STATES
WORKER_MODEL_TIERS = {
    "codex": CODEX_WORKER_TIER_FAMILIES,
    "claude": {
        "fast": "haiku",
        "balanced": "sonnet",
        "strong": "opus",
    },
}
CODEX_WORKER_EFFORTS = frozenset({"low", "medium", "high", "xhigh"})
CLAUDE_WORKER_EFFORTS = CODEX_WORKER_EFFORTS | frozenset({"max"})
GENERAL_MODEL_OPTIONS = {
    "codex": CODEX_FAMILIES,
    "claude": {"fable", "opus", "sonnet", "haiku"},
}
BASE_GENERAL_EFFORTS = frozenset({"low", "medium", "high", "xhigh"})
AUTO_DISPATCH_SOURCES = frozenset({"ready-sweeper", "dependency-progression", "orchestrator-review-retry"})
MAX_AUTO_DISPATCH_ATTEMPTS = 5
AUTO_DISPATCH_BACKOFF_SECONDS = 30.0
QUEUE_DRAIN_ACTIVE_STATES = frozenset({"active", "waiting", "blocked"})
QUEUE_DRAIN_TERMINAL_STATES = frozenset({"completed", "canceled"})
QUEUE_DRAIN_QUIESCENCE_SECONDS = 2.0
QUEUE_DRAIN_MONITOR_INTERVAL_SECONDS = 5.0
DEFAULT_WORKER_HEALTH_CHECK_SECONDS = 10 * 60.0
DETERMINISTIC_FAILURE_PREFIXES = (
    "missing worker sizing metadata",
    "invalid worker_model",
    "invalid worker_effort",
    "worker_model",
    "ticket snapshot materialization failed",
    "worker exited 0 but did not complete ticket",
)
DETERMINISTIC_PROVIDER_LAUNCH_MARKERS = (
    "model_reasoning_effort",
    "reasoning effort",
    "reasoning_effort",
    "--effort",
    "--model",
    "invalid value",
    "unsupported value",
)


def _process_is_alive(pid: Any) -> bool:
    try:
        process_id = int(pid)
    except (TypeError, ValueError):
        return False
    if process_id <= 0:
        return False
    try:
        os.kill(process_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


ORCHESTRATOR_ACTION_KINDS = frozenset({
    "create_ticket",
    "edit_ticket",
    "update_dependencies",
    "request_worker",
})
TICKET_CONFIG_PREFIX_RE = re.compile(
    r'^\s*prefix\s*=\s*["\']?([A-Za-z][A-Za-z0-9]*)["\']?\s*$',
    re.MULTILINE,
)
TICKET_CONFIG_NEXT_ID_RE = re.compile(r"^(\s*next_id\s*=\s*)(\d+)(\s*)$", re.MULTILINE)


def _notify_state(state: str, **kwargs: Any) -> None:
    msg = {"source": "orchestrator", "state": state, **kwargs}
    s = None
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.sendto(json.dumps(msg).encode(), str(VOICE_STATE_SOCK))
    except (OSError, ConnectionRefusedError):
        pass
    finally:
        if s is not None:
            s.close()


def _notify_orchestration_trace(
    kind: str,
    *,
    ticket_id: str | None = None,
    run_id: int | None = None,
    source: str = "orchestrator",
    message: str | None = None,
    relay_command_seq: int | str | None = None,
    relay_command_id: str | None = None,
) -> None:
    if (relay_command_seq is not None or relay_command_id) and not _relay_command_current(
        relay_command_seq,
        relay_command_id,
    ):
        return
    payload = _orchestration_trace_payload(
        kind,
        ticket_id=ticket_id,
        run_id=run_id,
        source=source,
        message=message,
        relay_command_seq=relay_command_seq,
        relay_command_id=relay_command_id,
    )
    if payload is not None:
        _notify_state("working", **payload)


def _orchestration_trace_payload(
    kind: str,
    *,
    ticket_id: str | None = None,
    run_id: int | None = None,
    source: str = "orchestrator",
    message: str | None = None,
    relay_command_seq: int | str | None = None,
    relay_command_id: str | None = None,
) -> dict[str, Any] | None:
    command = None
    if relay_command_seq is not None or relay_command_id:
        try:
            command = RelayCommandMetadata.from_dict({
                "relay_command_seq": relay_command_seq,
                "relay_command_id": relay_command_id,
            })
        except ValueError:
            command = None
    try:
        event = OrchestrationTraceEvent(
            kind=kind,
            source=source,
            message=message,
            command=command,
            ticket_id=ticket_id,
            run_id=run_id,
        )
    except ValueError as e:
        print(f"[orchestrator] could not build orchestration trace: {e}", file=sys.stderr)
        return
    payload: dict[str, Any] = {
        "text": event.message,
        "trace_event": event.to_dict(),
    }
    status_event = event.to_status_event_dict()
    if status_event is not None:
        payload["status_event"] = status_event
    return payload


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

def _data_root() -> Path:
    if sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    return base / "relay-runner" / "orchestrator"


def _program_registry_path() -> Path:
    return _data_root().parent / "program" / "projects.json"


def _registered_project_repo_paths(registry_path: Path) -> list[str]:
    try:
        payload = json.loads(registry_path.read_text())
    except (OSError, json.JSONDecodeError):
        return []
    projects = payload.get("projects") if isinstance(payload, dict) else None
    if not isinstance(projects, list):
        return []

    active_project = str(payload.get("activeProjectID") or "").strip()
    active_project_path = str(Path(active_project).expanduser().resolve()) if active_project else None
    active_workspace_root = str(payload.get("activeWorkspaceRootID") or "").strip()
    active_workspace_root_path = str(Path(active_workspace_root).expanduser().resolve()) if active_workspace_root else None
    workspace_roots = _registered_workspace_root_paths(payload)
    workspace_roots_to_filter = {
        path
        for path in workspace_roots
        if path != active_project_path or path == active_workspace_root_path
    }
    repo_paths: list[str] = []
    seen: set[str] = set()
    for record in projects:
        if not isinstance(record, dict):
            continue
        raw = record.get("repoPath") or record.get("id")
        repo_path = str(raw or "").strip()
        if not repo_path:
            continue
        resolved = str(Path(repo_path).expanduser().resolve())
        if resolved in workspace_roots_to_filter or resolved in seen:
            continue
        seen.add(resolved)
        repo_paths.append(resolved)
    return repo_paths


def _registered_workspace_root_paths(payload: dict[str, Any]) -> set[str]:
    roots = payload.get("workspaceRoots")
    if not isinstance(roots, list):
        return set()
    paths: set[str] = set()
    for record in roots:
        if not isinstance(record, dict):
            continue
        raw = record.get("rootPath") or record.get("id")
        root_path = str(raw or "").strip()
        if root_path:
            paths.add(str(Path(root_path).expanduser().resolve()))
    return paths


def _resolve_workspace_root(cfg_value: str) -> Path:
    if cfg_value:
        return Path(cfg_value).expanduser()
    return _data_root() / "workspaces"


def _resolve_workflow_default(cfg_value: str) -> Path:
    """Default workflow template: user override → bundled file alongside this script."""
    user_default = _data_root() / "WORKFLOW.md"
    if cfg_value:
        return Path(cfg_value).expanduser()
    if user_default.exists():
        return user_default
    return Path(__file__).with_name("orchestrator_workflow.md")


def _agent_kind(raw: str | None) -> str:
    value = (raw or "codex").strip().lower()
    name = os.path.basename(value)
    if "claude" in name:
        return "claude"
    return "codex"


def _find_agent_bin(agent: str, configured: str = "") -> str:
    if configured:
        expanded = os.path.expanduser(configured)
        if os.path.sep in expanded and os.access(expanded, os.X_OK):
            return expanded
        p = shutil.which(configured)
        if p:
            return p
        raise RuntimeError(f"{agent} CLI not found: {configured}")

    if agent == "claude":
        p = shutil.which("claude")
        if p:
            return p
        fallback = os.path.expanduser("~/.local/bin/claude")
        if os.access(fallback, os.X_OK):
            return fallback
        raise RuntimeError("claude CLI not found on PATH or at ~/.local/bin/claude")

    bundled_candidates = (
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
    )
    for candidate in bundled_candidates:
        if os.access(candidate, os.X_OK):
            return candidate
    p = shutil.which("codex")
    if p:
        return p
    raise RuntimeError("codex CLI not found on PATH or in the ChatGPT/Codex applications")


# ---------------------------------------------------------------------------
# Pure helpers (unit-testable)
# ---------------------------------------------------------------------------

_BRANCH_INVALID = re.compile(r"[^a-z0-9-]+")


def sanitize_identifier(identifier: str) -> str:
    """`REL-42` → `rel-42`. Lowercase, ASCII alnum + dashes only, no leading/trailing dashes."""
    s = (identifier or "").strip().lower()
    s = _BRANCH_INVALID.sub("-", s)
    s = re.sub(r"-{2,}", "-", s).strip("-")
    if not s:
        raise ValueError(f"Invalid identifier: {identifier!r}")
    return s


def workspace_slug(repo_path: str, ticket_id: str) -> str:
    """Stable worktree directory name scoped by repo, then ticket."""
    repo = Path(repo_path)
    repo_name = sanitize_identifier(repo.name or "repo")
    ticket = sanitize_identifier(ticket_id)
    digest = hashlib.sha1(str(repo.resolve()).encode("utf-8")).hexdigest()[:8]
    return f"{repo_name}-{digest}-{ticket}"


_TEMPLATE_RE = re.compile(r"\{\{\s*([\w_]+)\s*\}\}")


def render_template(template: str, **vars: Any) -> str:
    """Tiny `{{key}}` renderer. Missing keys → empty string. No escaping (we trust the template)."""
    return _TEMPLATE_RE.sub(lambda m: str(vars.get(m.group(1).strip(), "")), template)


def _ticket_frontmatter(ticket: dict[str, Any]) -> dict[str, str]:
    raw = ticket.get("_raw_fields")
    return raw if isinstance(raw, dict) else {}


def _required_sizing_value(ticket: dict[str, Any], field: str) -> str:
    value = str(_ticket_frontmatter(ticket).get(field) or "").strip()
    return value


def _resolve_worker_model(worker_model: str, agent_kind: str) -> str:
    value = worker_model.strip().lower()
    if ":" in value:
        provider, _, model = value.partition(":")
        model = model.strip()
        if provider not in ("codex", "claude") or not model:
            raise ValueError(f"invalid worker_model {worker_model!r}")
        if provider != agent_kind:
            raise ValueError(
                f"worker_model {worker_model!r} is scoped to {provider}, "
                f"but configured worker provider is {agent_kind}"
            )
        if agent_kind == "codex":
            return normalize_codex_family(model)
        return model

    model = WORKER_MODEL_TIERS.get(agent_kind, {}).get(value)
    if model is None:
        allowed = ", ".join(sorted(WORKER_MODEL_TIERS.get(agent_kind, {})))
        raise ValueError(
            f"invalid worker_model {worker_model!r} for {agent_kind}; "
            f"expected one of {allowed} or {agent_kind}:<model>"
        )
    return model


def _configured_orchestrator_model(general: dict[str, Any] | None) -> str | None:
    if not isinstance(general, dict):
        return None
    if str(general.get("subagent_sizing_policy") or "").strip().lower() != "user_default":
        return None
    model = str(general.get("model") or "").strip().lower()
    return model if model and model != "default" else None


def _uses_inherited_worker_defaults(general: dict[str, Any] | None) -> bool:
    return (
        isinstance(general, dict)
        and str(general.get("subagent_sizing_policy") or "").strip().lower() == "user_default"
    )


def _normalized_general_model(general: dict[str, Any], agent_kind: str) -> str:
    model = str(general.get("model") or "").strip().lower()
    if agent_kind == "codex":
        return normalize_codex_family(model)
    return model if model in GENERAL_MODEL_OPTIONS[agent_kind] else "opus"


def _general_effort_options(agent_kind: str, model: str) -> frozenset[str]:
    if agent_kind == "codex":
        return BASE_GENERAL_EFFORTS | frozenset({"max", "ultra"})
    if model in {"fable", "opus"}:
        return BASE_GENERAL_EFFORTS | frozenset({"max"})
    if model == "sonnet":
        return frozenset({"low", "medium", "high", "max"})
    return frozenset({"low"})


def _normalized_general_effort(general: dict[str, Any], agent_kind: str, model: str) -> str:
    effort = str(
        general.get("orchestrator_effort") or general.get("codex_reasoning_effort") or ""
    ).strip().lower()
    if effort == "default":
        effort = "xhigh"
    if effort in _general_effort_options(agent_kind, model):
        return effort
    return "xhigh" if "xhigh" in _general_effort_options(agent_kind, model) else "low"


def _inherited_worker_sizing(general: dict[str, Any], agent_kind: str) -> dict[str, str | None]:
    model = _normalized_general_model(general, agent_kind)
    effort = _normalized_general_effort(general, agent_kind, model)
    return {
        "provider_key": agent_kind,
        "model_alias": model,
        "worker_model": f"{agent_kind}:{model}",
        "worker_effort": effort,
        "worker_sizing_rationale": "Inherited provider, model, and effort from Relay Runner General Settings.",
        "worker_provider_notes": (
            "Use my defaults preserves explicit stable provider selections; Codex resolves "
            "Sol/Terra/Luna then uses model_reasoning_effort and Claude uses --effort."
        ),
    }


def _validate_worker_effort(worker_effort: str, *, worker_model: str, agent_kind: str,
                            provider_notes: str) -> str:
    effort = worker_effort.strip().lower()
    allowed = CLAUDE_WORKER_EFFORTS if agent_kind == "claude" else CODEX_WORKER_EFFORTS
    if effort not in allowed:
        allowed_text = ", ".join(sorted(allowed))
        raise ValueError(
            f"invalid worker_effort {worker_effort!r} for {agent_kind}; "
            f"expected one of {allowed_text}"
        )
    if effort == "max":
        scoped_to_claude = worker_model.strip().lower().startswith("claude:")
        notes_document_limitation = provider_notes.strip().lower() not in ("", "none")
        if not scoped_to_claude or not notes_document_limitation:
            raise ValueError(
                "worker_effort 'max' requires a Claude-scoped worker_model and "
                "worker_provider_notes documenting the Codex limitation"
            )
    return effort


def resolve_worker_sizing(
    ticket: dict[str, Any],
    agent_kind: str,
    general: dict[str, Any] | None = None,
) -> dict[str, str | None]:
    if _uses_inherited_worker_defaults(general):
        return _inherited_worker_sizing(general or {}, agent_kind)

    missing = [field for field in WORKER_SIZING_FIELDS if not _required_sizing_value(ticket, field)]
    if missing:
        raise ValueError("missing worker sizing metadata: " + ", ".join(missing))

    worker_model = _required_sizing_value(ticket, "worker_model")
    worker_effort = _required_sizing_value(ticket, "worker_effort")
    provider_notes = _required_sizing_value(ticket, "worker_provider_notes")
    model_alias = _configured_orchestrator_model(general) or _resolve_worker_model(worker_model, agent_kind)
    effort = _validate_worker_effort(
        worker_effort,
        worker_model=worker_model,
        agent_kind=agent_kind,
        provider_notes=provider_notes,
    )
    return {
        "provider_key": agent_kind,
        "model_alias": model_alias,
        "worker_model": worker_model,
        "worker_effort": effort,
        "worker_sizing_rationale": _required_sizing_value(ticket, "worker_sizing_rationale"),
        "worker_provider_notes": provider_notes,
    }


def raw_worker_sizing_metadata(ticket: dict[str, Any], agent_kind: str) -> dict[str, str | None]:
    return {
        "provider_key": agent_kind,
        "model_alias": None,
        "worker_model": _required_sizing_value(ticket, "worker_model") or None,
        "worker_effort": _required_sizing_value(ticket, "worker_effort") or None,
        "worker_sizing_rationale": _required_sizing_value(ticket, "worker_sizing_rationale") or None,
        "worker_provider_notes": _required_sizing_value(ticket, "worker_provider_notes") or None,
    }


def _normalized_default_worker_sizing(
    general: dict[str, Any],
    agent_kind: str | None = None,
) -> dict[str, str] | None:
    if not _uses_inherited_worker_defaults(general):
        return None
    effective_agent_kind = agent_kind or _provider_from_general(general, "codex")
    inherited = _inherited_worker_sizing(general, effective_agent_kind)
    return {field: str(inherited[field] or "") for field in WORKER_SIZING_FIELDS}


def apply_default_worker_sizing(
    ticket: dict[str, Any],
    general: dict[str, Any],
    agent_kind: str | None = None,
) -> bool:
    defaults = _normalized_default_worker_sizing(general, agent_kind=agent_kind)
    if not defaults:
        return False
    raw = ticket.setdefault("_raw_fields", {})
    if not isinstance(raw, dict):
        raw = {}
        ticket["_raw_fields"] = raw
    if all(str(raw.get(field) or "") == defaults[field] for field in WORKER_SIZING_FIELDS):
        return False
    raw.update(defaults)
    return True


def _provider_from_general(general: dict[str, Any], fallback: str) -> str:
    return _agent_kind(str(general.get("provider") or general.get("command") or fallback or "codex"))


def _dispatch_failure_signature(reason: str | None) -> str | None:
    text = re.sub(r"\s+", " ", str(reason or "")).strip()
    if not text:
        return None
    return text.lower()


def _is_deterministic_provider_launch_failure(signature: str) -> bool:
    if not signature.startswith("exit="):
        return False
    if "http 400" not in signature and "bad request" not in signature and "invalid request" not in signature:
        return False
    return any(marker in signature for marker in DETERMINISTIC_PROVIDER_LAUNCH_MARKERS)


def _is_deterministic_dispatch_failure(reason: str | None) -> bool:
    signature = _dispatch_failure_signature(reason)
    if not signature:
        return False
    if any(signature.startswith(prefix) for prefix in DETERMINISTIC_FAILURE_PREFIXES):
        return True
    return _is_deterministic_provider_launch_failure(signature)


def _materialize_ticket_snapshot(
    *,
    ticket_file: Path,
    workspace_path: Path,
    ticket_id: str,
) -> None:
    try:
        snapshot = ticket_file.read_bytes()
        dest = workspace_path / ".orchestrator" / f"{ticket_id}.md"
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_name(dest.name + ".tmp")
        tmp.write_bytes(snapshot)
        os.replace(tmp, dest)

        attachment_source = ticket_file.parent / "attachments" / ticket_id
        if attachment_source.is_dir():
            attachment_dest = workspace_path / ".orchestrator" / "attachments" / ticket_id
            shutil.copytree(attachment_source, attachment_dest, dirs_exist_ok=True)
    except (OSError, shutil.Error) as e:
        raise RuntimeError(f"ticket snapshot materialization failed for {ticket_id}: {e}") from e


def _clean_required_text(value: Any, field: str) -> str:
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    if not text:
        raise ValueError(f"{field} is required")
    return text


def _clean_optional_text(value: Any) -> str | None:
    if value is None:
        return None
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    return text or None


def _clean_optional_multiline_text(value: Any) -> str | None:
    if value is None:
        return None
    lines = [re.sub(r"\s+", " ", line).strip() for line in str(value or "").splitlines()]
    text = "\n".join(line for line in lines if line).strip()
    return text or None


def _clean_markdown(value: Any, field: str) -> str:
    text = str(value or "").strip()
    if not text:
        raise ValueError(f"{field} is required")
    return text


def _string_list(value: Any, field: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError(f"{field} must be a list")
    return [str(item).strip() for item in value if str(item).strip()]


def _ticket_id_list(value: Any, field: str) -> list[str]:
    return [item.upper() for item in _string_list(value, field)]


def _ticket_config(config_path: Path) -> tuple[str, int, str]:
    try:
        text = config_path.read_text()
    except OSError as e:
        raise ValueError(f"could not read {config_path}: {e}") from e
    prefix_match = TICKET_CONFIG_PREFIX_RE.search(text)
    next_match = TICKET_CONFIG_NEXT_ID_RE.search(text)
    if not prefix_match or not next_match:
        raise ValueError("invalid .orchestrator/config.toml: expected prefix and next_id")
    return prefix_match.group(1).upper(), int(next_match.group(2)), text


def _write_ticket_config_next_id(config_path: Path, config_text: str, next_id: int) -> None:
    updated = TICKET_CONFIG_NEXT_ID_RE.sub(
        lambda match: f"{match.group(1)}{next_id}{match.group(3)}",
        config_text,
        count=1,
    )
    if not updated.endswith("\n"):
        updated += "\n"
    config_path.write_text(updated)


def _mint_ticket_id(repo: Path) -> str:
    orch_dir = repo / ".orchestrator"
    prefix, next_id, config_text = _ticket_config(orch_dir / "config.toml")
    ticket_number = next_id
    while (orch_dir / f"{prefix}-{ticket_number}.md").exists():
        ticket_number += 1
    _write_ticket_config_next_id(orch_dir / "config.toml", config_text, ticket_number + 1)
    return f"{prefix}-{ticket_number}"


def _advance_ticket_config_past(repo: Path, ticket_id: str) -> None:
    orch_dir = repo / ".orchestrator"
    prefix, next_id, config_text = _ticket_config(orch_dir / "config.toml")
    match = re.fullmatch(rf"{re.escape(prefix)}-(\d+)", ticket_id.upper())
    if match is None:
        return
    ticket_number = int(match.group(1))
    if ticket_number >= next_id:
        _write_ticket_config_next_id(orch_dir / "config.toml", config_text, ticket_number + 1)


def _acceptance_criteria_lines(value: Any) -> list[str]:
    criteria = _string_list(value, "acceptance_criteria")
    if not criteria:
        raise ValueError("acceptance_criteria is required")
    return criteria


def _structured_ticket_body(description: str, acceptance_criteria: list[str]) -> str:
    checks = "\n".join(f"- [ ] {item}" for item in acceptance_criteria)
    return f"## Description\n\n{description}\n\n## Acceptance criteria\n\n{checks}\n"


def _action_worker_sizing(action: dict[str, Any]) -> dict[str, str]:
    sizing = {
        field: _clean_required_text(action.get(field), field)
        for field in WORKER_SIZING_FIELDS
    }
    effort = sizing["worker_effort"].lower()
    if effort not in CLAUDE_WORKER_EFFORTS:
        raise ValueError(f"invalid worker_effort {sizing['worker_effort']!r}")
    sizing["worker_effort"] = effort
    return sizing


def _execution_mode(value: Any) -> str:
    mode = str(value or "implementation").strip().lower()
    if mode not in EXECUTION_MODES:
        raise ValueError(f"invalid execution_mode: {mode!r}")
    return mode


def _apply_ticket_action_fields(ticket: dict[str, Any], action: dict[str, Any]) -> None:
    if "title" in action:
        ticket["title"] = _clean_required_text(action.get("title"), "title")
    if "priority" in action:
        priority = str(action.get("priority") or "").strip().lower()
        if priority not in ("urgent", "high", "medium", "low"):
            raise ValueError(f"invalid priority: {priority!r}")
        ticket["priority"] = priority
    if "depends_on" in action:
        ticket["depends_on"] = _ticket_id_list(action.get("depends_on"), "depends_on")
    if "execution_mode" in action:
        ticket["execution_mode"] = _execution_mode(action.get("execution_mode"))
    if "description" in action or "acceptance_criteria" in action:
        description = _clean_markdown(
            action.get("description") if "description" in action else _body_section(ticket, "Description"),
            "description",
        )
        criteria = (
            _acceptance_criteria_lines(action.get("acceptance_criteria"))
            if "acceptance_criteria" in action
            else _body_acceptance_criteria(ticket)
        )
        ticket["body"] = _structured_ticket_body(description, criteria)
    raw = ticket.setdefault("_raw_fields", {})
    if not isinstance(raw, dict):
        raw = {}
        ticket["_raw_fields"] = raw
    if any(field in action for field in WORKER_SIZING_FIELDS):
        for field, value in _action_worker_sizing(action).items():
            raw[field] = value


def _body_section(ticket: dict[str, Any], heading: str) -> str:
    body = str(ticket.get("body") or "")
    pattern = re.compile(rf"^## {re.escape(heading)}\s*\n(.*?)(?=^## |\Z)", re.MULTILINE | re.DOTALL)
    match = pattern.search(body)
    return match.group(1).strip() if match else ""


def _body_acceptance_criteria(ticket: dict[str, Any]) -> list[str]:
    section = _body_section(ticket, "Acceptance criteria")
    criteria: list[str] = []
    for line in section.splitlines():
        stripped = line.strip()
        if stripped.startswith("- [ ] "):
            criteria.append(stripped[6:].strip())
        elif stripped.startswith("- [x] ") or stripped.startswith("- [X] "):
            criteria.append(stripped[6:].strip())
    if not criteria:
        raise ValueError("acceptance_criteria is required")
    return criteria


def _relay_command_current(relay_command_seq: int | str | None, relay_command_id: str | None) -> bool:
    if relay_command_seq is None or not relay_command_id:
        return False
    try:
        current = json.loads(RELAY_COMMAND_STATE_FILE.read_text())
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return False
    if not isinstance(current, dict):
        return False
    try:
        current_seq = int(current.get("relay_command_seq"))
        expected_seq = int(relay_command_seq)
    except (TypeError, ValueError):
        return False
    return (
        current_seq == expected_seq
        and str(current.get("relay_command_id") or "") == str(relay_command_id)
    )


def _validate_relay_command(
    relay_command_seq: Any,
    relay_command_id: Any,
    *,
    relay_intent_id: str | None = None,
    mutation: dict[str, Any] | None = None,
) -> None:
    if relay_command_seq is None and not relay_command_id:
        return
    current = _relay_command_current(relay_command_seq, str(relay_command_id or ""))
    if current:
        if mutation is not None and authorization_exists(
            RELAY_COMMAND_AUTHORIZATION_FILE,
            relay_command_seq,
            relay_command_id,
        ):
            validate_and_mark_mutation(
                RELAY_COMMAND_AUTHORIZATION_FILE,
                relay_command_seq,
                relay_command_id,
                mutation,
                relay_intent_id=relay_intent_id,
            )
        return
    if mutation is not None:
        validate_and_mark_mutation(
            RELAY_COMMAND_AUTHORIZATION_FILE,
            relay_command_seq,
            relay_command_id,
            mutation,
            relay_intent_id=relay_intent_id,
        )
        return
    raise ValueError("stale Relay command: a newer voice command has superseded this action")


def _relay_mutation_metadata(
    kind: str,
    *,
    ticket_id: str | None = None,
    action_kind: str | None = None,
    action_index: int | None = None,
    request_id: str | None = None,
) -> dict[str, Any]:
    mutation: dict[str, Any] = {"kind": kind}
    if ticket_id:
        mutation["ticket_id"] = str(ticket_id).strip().upper()
    if action_kind:
        mutation["action_kind"] = str(action_kind).strip()
    if action_index is not None:
        mutation["action_index"] = action_index
    if request_id:
        mutation["request_id"] = request_id
    return mutation


def _orchestrator_action_mutation(
    raw_action: dict[str, Any],
    *,
    action_index: int,
    request_id: str | None,
) -> dict[str, Any]:
    return _relay_mutation_metadata(
        "orchestrator_action",
        ticket_id=str(raw_action.get("ticket_id") or "").strip().upper() or None,
        action_kind=str(raw_action.get("kind") or "").strip().lower(),
        action_index=action_index,
        request_id=request_id,
    )


def _relay_canceled_entry(mutation: dict[str, Any], reason: str) -> dict[str, Any]:
    entry = {
        "action": mutation.get("action_kind") or mutation.get("kind"),
        "reason": reason,
    }
    if mutation.get("ticket_id"):
        entry["ticket_id"] = mutation["ticket_id"]
    return entry


def _autonomous_worker_sizing(general: dict[str, Any]) -> dict[str, str]:
    defaults = _normalized_default_worker_sizing(general)
    if defaults:
        return defaults
    return {
        "worker_model": "balanced",
        "worker_effort": "medium",
        "worker_sizing_rationale": (
            "Autonomous Relay command authoring used a conservative default "
            "because the PM did not supply explicit sizing."
        ),
        "worker_provider_notes": (
            "Codex uses model_reasoning_effort and Claude uses --effort; "
            "the backstage authoring loop writes the same ticket schema for both providers."
        ),
    }


_GENERIC_TICKET_REQUEST_RE = re.compile(
    r"\b(ticket|card|task|issue)\b.*\b(this|that|conversation|discussion|what\s+we\s+discussed|also)\b"
    r"|\b(write|create|make)\b.*\b(ticket|card|task|issue)\b",
    re.IGNORECASE,
)
_PRIVATE_CONTEXT_LINE_RE = re.compile(
    r"\b(raw\s+transcript|source_text|hidden\s+reasoning|tool\s+log|shell\s+output|scratchpad|prompt)\b"
    r"|(`|\$\(|&&|\|\||\s;\s|"
    r"\b(?:bash|cat|curl|git|grep|npm|pnpm|python|python3|sh|swift|xcodebuild|yarn|zsh)\s+)",
    re.IGNORECASE,
)


def _sanitize_refined_ticket_context(value: Any) -> str | None:
    text = _clean_optional_multiline_text(value)
    if not text:
        return None
    lines: list[str] = []
    for raw in text.splitlines():
        line = re.sub(r"\s+", " ", raw).strip()
        if not line or _PRIVATE_CONTEXT_LINE_RE.search(line):
            continue
        lines.append(line)
        if len(lines) >= 18:
            break
    sanitized = "\n".join(lines).strip()
    return sanitized[:2400].rstrip() if sanitized else None


def _context_title(context: str, source_text: str) -> str:
    for line in context.splitlines():
        match = re.match(r"^(?:title|ticket)\s*:\s*(.+)$", line, re.IGNORECASE)
        candidate = match.group(1) if match else line
        candidate = re.sub(r"^[-*]\s*(?:\[[ xX]\]\s*)?", "", candidate).strip()
        if candidate:
            title = candidate.rstrip(".")
            return title[:73].rstrip() + "..." if len(title) > 76 else title
    return refined_ticket_title(source_text)


def _context_acceptance_criteria(context: str) -> list[str]:
    criteria: list[str] = []
    in_section = False
    for line in context.splitlines():
        stripped = line.strip()
        if re.match(r"^acceptance\s+criteria\s*:?\s*$", stripped, re.IGNORECASE):
            in_section = True
            continue
        bullet = re.match(r"^[-*]\s*(?:\[[ xX]\]\s*)?(.+)$", stripped)
        if bullet and (in_section or len(criteria) < 4):
            item = bullet.group(1).strip().rstrip(".")
            if item:
                criteria.append(item)
        elif in_section and stripped and not re.match(r"^[A-Za-z ]+:$", stripped):
            criteria.append(stripped.rstrip("."))
        if len(criteria) >= 6:
            break
    return criteria


def _generic_ticket_request_without_context(source_text: str) -> bool:
    summary = refined_command_summary(source_text).lower()
    generic_summary = any(
        phrase in summary
        for phrase in (
            "ticket also",
            "ticket conversation",
            "ticket discussion",
            "requested project change",
        )
    )
    return bool(_GENERIC_TICKET_REQUEST_RE.search(source_text or "") and generic_summary)


def _autonomous_ticket_action(
    source_text: str,
    general: dict[str, Any],
    refined_context: str | None = None,
) -> dict[str, Any]:
    context = _sanitize_refined_ticket_context(refined_context)
    if not context and _generic_ticket_request_without_context(source_text):
        raise ValueError(
            "Blocked generic ticket request: PM-refined conversation context is required "
            "before creating a visible ticket."
        )

    summary = refined_command_summary(source_text)
    title = refined_ticket_title(source_text)
    description = (
        f"Backstage orchestrator summary: {summary}\n\n"
        "Use the repository context to identify the affected files and exact behavior. "
        "The raw Relay transcript remains private orchestrator metadata and is not part "
        "of this visible ticket."
    )
    criteria = [
        "The requested behavior summarized above is implemented in the active repo.",
        "Focused verification covers the affected behavior or the run log explains why verification was not practical.",
        "The worker run log records what changed and any follow-up needed.",
    ]
    if context:
        title = _context_title(context, source_text)
        description = (
            "PM-refined context:\n\n"
            f"{context}\n\n"
            "Raw Relay transcripts, hidden reasoning, tool logs, and shell output remain "
            "private orchestrator metadata and are not part of this visible ticket."
        )
        context_criteria = _context_acceptance_criteria(context)
        if context_criteria:
            criteria = context_criteria

    return {
        "kind": "create_ticket",
        "title": title,
        "description": description,
        "acceptance_criteria": criteria,
        "priority": "medium",
        "depends_on": [],
        **_autonomous_worker_sizing(general),
    }


# -- live activity summary (RR-12) ------------------------------------------
# A worker's most recent tool call, distilled to a ≤60-char chip for the board.
# No-op tools shouldn't clobber a more useful activity set moments earlier; the
# heartbeat keeps `activity_at` fresh while a long-running tool is in flight so
# the board doesn't false-positive into "Idle".
ACTIVITY_MAX_LEN = 60
ACTIVITY_DEBOUNCE_SECONDS = 5.0
ACTIVITY_HEARTBEAT_SECONDS = 5.0
_NOOP_TOOLS = frozenset({"TodoWrite"})
_SHELL_NAMES = frozenset({"sh", "bash", "zsh"})


def _clip(text: str, limit: int = ACTIVITY_MAX_LEN) -> str:
    text = (text or "").strip()
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


def _shell_words(command: str) -> list[str]:
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


def _unwrap_shell_command(command: str) -> str:
    lines = (command or "").strip().splitlines()
    first = lines[0].strip() if lines else ""
    words = _shell_words(first)
    if not words:
        return ""

    if os.path.basename(words[0]) == "env" and len(words) > 1:
        i = 1
        while i < len(words) and (words[i].startswith("-") or "=" in words[i]):
            i += 1
        if i < len(words):
            words = words[i:]

    if os.path.basename(words[0]) in _SHELL_NAMES:
        for i, word in enumerate(words[1:], start=1):
            if word == "-c" or (word.startswith("-") and "c" in word[1:]):
                if i + 1 < len(words):
                    return words[i + 1].strip()
                break
    return first


def _activity_from_description(description: str) -> str:
    desc = (description or "").strip()
    if not desc:
        return ""
    return _clip(desc[:1].upper() + desc[1:])


def _task_activity(task: str) -> str:
    return {
        "test": "Running tests",
        "lint": "Running lint",
        "build": "Running build",
    }.get(task, "Running project task")


def _semantic_shell_activity(command: str, description: str = "") -> str:
    cmd = _unwrap_shell_command(command)
    lower = re.sub(r"\s+", " ", cmd.lower()).strip()
    words = _shell_words(cmd)
    first = os.path.basename(words[0]) if words else ""

    if not lower:
        return _activity_from_description(description) or "Running command"

    if "apply_patch" in lower:
        return "Editing source files"

    if re.search(r"\b(swift test|xcodebuild\b.*\btest\b)\b", lower):
        return "Running Swift tests"
    if re.search(r"\b(swift build|xcodebuild)\b", lower):
        return "Running Swift build"
    if re.search(r"\b(pytest|python3? -m pytest)\b", lower):
        return "Running Python tests"
    if re.search(r"\b(npm|pnpm|yarn) (run )?(test|lint|build)\b", lower):
        task = re.search(r"\b(test|lint|build)\b", lower)
        return _task_activity(task.group(1)) if task else "Running project task"
    if re.search(r"\b(make|just) (test|lint|build)\b", lower):
        task = re.search(r"\b(test|lint|build)\b", lower)
        return _task_activity(task.group(1)) if task else "Running project task"

    if re.search(r"\b(git grep|rg|grep)\b", lower):
        return "Searching source files"
    if first in {"find", "fd"}:
        return "Finding files"
    if first in {"cat", "sed", "head", "tail", "nl", "wc"}:
        return "Reading source files"
    if first in {"ls", "pwd", "tree"} or re.search(r"\bgit ls-files\b", lower):
        return "Inspecting workspace"

    if re.search(r"\bgit commit\b", lower):
        return "Committing changes"
    if re.search(r"\bgit add\b", lower):
        return "Staging changes"
    if re.search(r"\bgit status\b", lower):
        return "Checking git status"
    if re.search(r"\bgit (diff|show|log)\b", lower):
        return "Inspecting git changes"
    if re.search(r"\bgit \w+", lower):
        return "Working with git"

    return _activity_from_description(description) or "Investigating"


def derive_activity(tool_name: str, tool_input: dict | None) -> str:
    """Heuristic summary of a worker's current tool call. Intentionally
    approximate — grow this table as new tools matter (see RR-12)."""
    ti = tool_input or {}
    name = tool_name or ""

    def base(p: Any) -> str:
        s = str(p or "")
        return os.path.basename(s) or s

    if name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        f = ti.get("file_path") or ti.get("notebook_path") or ""
        return _clip(f"Editing {base(f)}" if f else "Editing")
    if name == "Read":
        f = ti.get("file_path") or ""
        return _clip(f"Reading {base(f)}" if f else "Reading")
    if name in ("Grep", "Glob"):
        return "Searching"
    if name == "Bash":
        cmd = (ti.get("command") or "").strip()
        desc = (ti.get("description") or "").strip()
        return _semantic_shell_activity(cmd, desc)
    if name in ("WebFetch", "WebSearch"):
        return "Researching"
    if name == "Task":
        return "Delegating to sub-agent"
    if name == "TodoWrite":
        return "Planning"
    # Unknown / MCP tools: just show the (clipped) tool name.
    return _clip(name) or "Working"


def derive_codex_activity(item: dict | None) -> str:
    """Heuristic summary for Codex exec --json item events."""
    item = item or {}
    itype = item.get("type") or ""
    if itype == "command_execution":
        command = (item.get("command") or "").strip()
        return _semantic_shell_activity(command)
    if itype == "file_change":
        changes = item.get("changes") or []
        paths = [str(c.get("path") or "") for c in changes if isinstance(c, dict)]
        if any(f"{os.sep}.orchestrator{os.sep}" in path for path in paths):
            return "Updating ticket run log"
        return "Editing source files"
    name = item.get("name") or item.get("tool_name") or itype
    if str(name).endswith("apply_patch") or str(name) == "apply_patch":
        return "Editing source files"
    return _clip(str(name)) or "Working"


# ---------------------------------------------------------------------------
# Stores
# ---------------------------------------------------------------------------

def _json_list(raw: Any) -> list[str]:
    if isinstance(raw, list):
        return [str(item) for item in raw if str(item)]
    if not raw:
        return []
    try:
        decoded = json.loads(str(raw))
    except (json.JSONDecodeError, TypeError, ValueError):
        return []
    if not isinstance(decoded, list):
        return []
    return [str(item) for item in decoded if str(item)]


def _queue_drain_id(repo_path: str, target_branch: str, provider_key: str, sequence: int) -> str:
    digest = hashlib.sha1(
        f"{Path(repo_path).expanduser().resolve()}|{target_branch}|{provider_key}|{sequence}".encode("utf-8")
    ).hexdigest()[:12]
    return f"drain-{digest}-{sequence}"


def _provider_goal_mode(provider_key: str) -> str:
    provider = OrchestratorSessionStore._normalize_provider(provider_key)
    if provider == "codex":
        return "codex-goal-lifecycle"
    # The installed Claude CLI exposes background agents but no documented goal
    # primitive equivalent to Codex /goal, so Relay Runner supplies persistence.
    return "relay-runner-durable-goal"


class QueueDrainStore:
    """Durable rolling queue-drain goal records.

    The board and ticket files remain the source of truth for user work. This
    store is the daemon's restartable liveness ledger: which tickets joined the
    current drain, why each ticket is active/scheduled/waiting/blocked, and when
    the drain has stayed quiescent long enough to complete.
    """

    SCHEMA_VERSION = 1

    SCHEMA = """
    CREATE TABLE IF NOT EXISTS queue_drains (
        id TEXT PRIMARY KEY,
        repo_path TEXT NOT NULL,
        target_branch TEXT NOT NULL,
        provider_key TEXT NOT NULL,
        provider_goal_id TEXT,
        provider_goal_state TEXT NOT NULL,
        provider_goal_mode TEXT NOT NULL,
        state TEXT NOT NULL,
        status_message TEXT,
        observed_ticket_ids TEXT NOT NULL DEFAULT '[]',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        quiescent_since REAL,
        completed_at REAL,
        canceled_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_queue_drains_repo_state
        ON queue_drains(repo_path, state);
    CREATE TABLE IF NOT EXISTS queue_drain_items (
        drain_id TEXT NOT NULL,
        ticket_id TEXT NOT NULL,
        state TEXT NOT NULL,
        run_id INTEGER,
        reason TEXT,
        next_action_at REAL,
        blocker_owner TEXT,
        blocker_next_step TEXT,
        unresolved_dependencies TEXT NOT NULL DEFAULT '[]',
        updated_at REAL NOT NULL,
        PRIMARY KEY(drain_id, ticket_id)
    );
    CREATE INDEX IF NOT EXISTS idx_queue_drain_items_ticket
        ON queue_drain_items(ticket_id);
    """

    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._init()

    @contextmanager
    def _conn(self):
        with self._lock:
            conn = sqlite3.connect(str(self.path), isolation_level=None)
            conn.row_factory = sqlite3.Row
            try:
                yield conn
            finally:
                conn.close()

    def _init(self) -> None:
        with self._conn() as c:
            current = int(c.execute("PRAGMA user_version").fetchone()[0])
            if current != self.SCHEMA_VERSION:
                c.execute("DROP TABLE IF EXISTS queue_drain_items")
                c.execute("DROP TABLE IF EXISTS queue_drains")
                c.executescript(self.SCHEMA)
                c.execute(f"PRAGMA user_version = {self.SCHEMA_VERSION}")
            else:
                c.executescript(self.SCHEMA)

    def active_for_repo(self, repo_path: str) -> dict[str, Any] | None:
        repo = str(Path(repo_path).expanduser().resolve())
        placeholders = ",".join("?" * len(QUEUE_DRAIN_ACTIVE_STATES))
        with self._conn() as c:
            row = c.execute(
                f"SELECT * FROM queue_drains WHERE repo_path = ? AND state IN ({placeholders}) "
                "ORDER BY created_at DESC LIMIT 1",
                (repo, *sorted(QUEUE_DRAIN_ACTIVE_STATES)),
            ).fetchone()
            return self._public_drain(c, row) if row else None

    def active_repo_paths(self) -> list[str]:
        placeholders = ",".join("?" * len(QUEUE_DRAIN_ACTIVE_STATES))
        with self._conn() as c:
            rows = c.execute(
                f"SELECT DISTINCT repo_path FROM queue_drains WHERE state IN ({placeholders})",
                tuple(sorted(QUEUE_DRAIN_ACTIVE_STATES)),
            ).fetchall()
            return [str(row["repo_path"]) for row in rows]

    def ensure_active(
        self,
        *,
        repo_path: str,
        target_branch: str,
        provider_key: str,
        observed_ticket_ids: list[str],
        status_message: str | None = None,
    ) -> tuple[dict[str, Any], bool]:
        repo = str(Path(repo_path).expanduser().resolve())
        provider = OrchestratorSessionStore._normalize_provider(provider_key)
        target = str(target_branch or "main")
        observed = sorted({str(ticket_id).upper() for ticket_id in observed_ticket_ids if str(ticket_id).strip()})
        now = time.time()
        with self._conn() as c:
            placeholders = ",".join("?" * len(QUEUE_DRAIN_ACTIVE_STATES))
            row = c.execute(
                f"SELECT * FROM queue_drains WHERE repo_path = ? AND state IN ({placeholders}) "
                "ORDER BY created_at DESC LIMIT 1",
                (repo, *sorted(QUEUE_DRAIN_ACTIVE_STATES)),
            ).fetchone()
            if row:
                merged = sorted(set(_json_list(row["observed_ticket_ids"])) | set(observed))
                c.execute(
                    "UPDATE queue_drains SET observed_ticket_ids = ?, updated_at = ? WHERE id = ?",
                    (json.dumps(merged), now, row["id"]),
                )
                fresh = c.execute("SELECT * FROM queue_drains WHERE id = ?", (row["id"],)).fetchone()
                return self._public_drain(c, fresh), False

            row = c.execute(
                "SELECT COUNT(*) AS count FROM queue_drains WHERE repo_path = ? AND target_branch = ? "
                "AND provider_key = ?",
                (repo, target, provider),
            ).fetchone()
            sequence = int(row["count"] or 0) + 1
            drain_id = _queue_drain_id(repo, target, provider, sequence)
            provider_goal_mode = _provider_goal_mode(provider)
            provider_goal_id = f"{provider}:{drain_id}" if provider == "codex" else drain_id
            message = status_message or f"Draining {len(observed)} queued/in-progress ticket(s)."
            c.execute(
                "INSERT INTO queue_drains("
                "id, repo_path, target_branch, provider_key, provider_goal_id, provider_goal_state, "
                "provider_goal_mode, state, status_message, observed_ticket_ids, created_at, updated_at"
                ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    drain_id,
                    repo,
                    target,
                    provider,
                    provider_goal_id,
                    "active",
                    provider_goal_mode,
                    "active",
                    message,
                    json.dumps(observed),
                    now,
                    now,
                ),
            )
            fresh = c.execute("SELECT * FROM queue_drains WHERE id = ?", (drain_id,)).fetchone()
            return self._public_drain(c, fresh), True

    def update_items(self, drain_id: str, items: list[dict[str, Any]]) -> None:
        now = time.time()
        with self._conn() as c:
            for item in items:
                c.execute(
                    "INSERT INTO queue_drain_items("
                    "drain_id, ticket_id, state, run_id, reason, next_action_at, blocker_owner, "
                    "blocker_next_step, unresolved_dependencies, updated_at"
                    ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
                    "ON CONFLICT(drain_id, ticket_id) DO UPDATE SET "
                    "state = excluded.state, run_id = excluded.run_id, reason = excluded.reason, "
                    "next_action_at = excluded.next_action_at, blocker_owner = excluded.blocker_owner, "
                    "blocker_next_step = excluded.blocker_next_step, "
                    "unresolved_dependencies = excluded.unresolved_dependencies, updated_at = excluded.updated_at",
                    (
                        drain_id,
                        str(item["ticket_id"]).upper(),
                        item.get("state") or "unknown",
                        item.get("run_id"),
                        item.get("reason"),
                        item.get("next_action_at"),
                        item.get("blocker_owner"),
                        item.get("blocker_next_step"),
                        json.dumps(item.get("unresolved_dependencies") or []),
                        now,
                    ),
                )

    def update_state(
        self,
        drain_id: str,
        *,
        state: str,
        provider_goal_state: str | None = None,
        status_message: str | None = None,
        quiescent_since: float | None = None,
        complete: bool = False,
        canceled: bool = False,
    ) -> dict[str, Any] | None:
        now = time.time()
        fields = ["state = ?", "updated_at = ?"]
        values: list[Any] = [state, now]
        if provider_goal_state is not None:
            fields.append("provider_goal_state = ?")
            values.append(provider_goal_state)
        if status_message is not None:
            fields.append("status_message = ?")
            values.append(status_message)
        fields.append("quiescent_since = ?")
        values.append(quiescent_since)
        if complete:
            fields.append("completed_at = ?")
            values.append(now)
        if canceled:
            fields.append("canceled_at = ?")
            values.append(now)
        values.append(drain_id)
        with self._conn() as c:
            c.execute(f"UPDATE queue_drains SET {', '.join(fields)} WHERE id = ?", values)
            row = c.execute("SELECT * FROM queue_drains WHERE id = ?", (drain_id,)).fetchone()
            return self._public_drain(c, row) if row else None

    def append_observed(self, drain_id: str, ticket_ids: list[str]) -> dict[str, Any] | None:
        normalized = {str(ticket_id).upper() for ticket_id in ticket_ids if str(ticket_id).strip()}
        with self._conn() as c:
            row = c.execute("SELECT * FROM queue_drains WHERE id = ?", (drain_id,)).fetchone()
            if not row:
                return None
            merged = sorted(set(_json_list(row["observed_ticket_ids"])) | normalized)
            c.execute(
                "UPDATE queue_drains SET observed_ticket_ids = ?, updated_at = ? WHERE id = ?",
                (json.dumps(merged), time.time(), drain_id),
            )
            fresh = c.execute("SELECT * FROM queue_drains WHERE id = ?", (drain_id,)).fetchone()
            return self._public_drain(c, fresh)

    def cancel(self, drain_id: str, *, reason: str | None = None) -> dict[str, Any] | None:
        message = reason or "Queue drain canceled by user."
        return self.update_state(
            drain_id,
            state="canceled",
            provider_goal_state="canceled",
            status_message=message,
            quiescent_since=None,
            canceled=True,
        )

    def list(self, *, repo_path: str | None = None, include_terminal: bool = False, limit: int = 20) -> list[dict[str, Any]]:
        limit = max(1, int(limit or 20))
        repo = str(Path(repo_path).expanduser().resolve()) if repo_path else None
        clauses: list[str] = []
        values: list[Any] = []
        if repo:
            clauses.append("repo_path = ?")
            values.append(repo)
        if not include_terminal:
            placeholders = ",".join("?" * len(QUEUE_DRAIN_TERMINAL_STATES))
            clauses.append(f"state NOT IN ({placeholders})")
            values.extend(sorted(QUEUE_DRAIN_TERMINAL_STATES))
        where = f"WHERE {' AND '.join(clauses)} " if clauses else ""
        values.append(limit)
        with self._conn() as c:
            rows = c.execute(
                f"SELECT * FROM queue_drains {where}ORDER BY created_at DESC LIMIT ?",
                values,
            ).fetchall()
            return [self._public_drain(c, row) for row in rows]

    def get(self, drain_id: str) -> dict[str, Any] | None:
        with self._conn() as c:
            row = c.execute("SELECT * FROM queue_drains WHERE id = ?", (drain_id,)).fetchone()
            return self._public_drain(c, row) if row else None

    def _items(self, conn: sqlite3.Connection, drain_id: str) -> list[dict[str, Any]]:
        rows = conn.execute(
            "SELECT * FROM queue_drain_items WHERE drain_id = ? ORDER BY ticket_id",
            (drain_id,),
        ).fetchall()
        return [
            {
                "ticket_id": row["ticket_id"],
                "state": row["state"],
                "run_id": row["run_id"],
                "reason": row["reason"],
                "next_action_at": row["next_action_at"],
                "blocker_owner": row["blocker_owner"],
                "blocker_next_step": row["blocker_next_step"],
                "unresolved_dependencies": _json_list(row["unresolved_dependencies"]),
                "updated_at": row["updated_at"],
            }
            for row in rows
        ]

    def _public_drain(self, conn: sqlite3.Connection, row: sqlite3.Row | None) -> dict[str, Any]:
        if row is None:
            return {}
        return {
            "id": row["id"],
            "repo_path": row["repo_path"],
            "target_branch": row["target_branch"],
            "provider_key": row["provider_key"],
            "provider_goal_id": row["provider_goal_id"],
            "provider_goal_state": row["provider_goal_state"],
            "provider_goal_mode": row["provider_goal_mode"],
            "state": row["state"],
            "status_message": row["status_message"],
            "observed_ticket_ids": _json_list(row["observed_ticket_ids"]),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "quiescent_since": row["quiescent_since"],
            "completed_at": row["completed_at"],
            "canceled_at": row["canceled_at"],
            "items": self._items(conn, row["id"]),
        }


class RunsStore:
    SCHEMA_VERSION = 5  # bump when the runs table shape changes

    SCHEMA = """
    CREATE TABLE IF NOT EXISTS runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ticket_id TEXT NOT NULL,
        repo_path TEXT NOT NULL,
        workspace_path TEXT NOT NULL,
        branch TEXT NOT NULL,
        execution_mode TEXT NOT NULL DEFAULT 'implementation',
        state TEXT NOT NULL,
        attempt INTEGER NOT NULL DEFAULT 1,
        pid INTEGER,
        started_at REAL NOT NULL,
        ended_at REAL,
        exit_code INTEGER,
        log_path TEXT,
        last_error TEXT,
        activity TEXT,
        activity_at REAL,
        provider_key TEXT,
        model_alias TEXT,
        worker_model TEXT,
        worker_effort TEXT,
        worker_sizing_rationale TEXT,
        worker_provider_notes TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_runs_state ON runs(state);
    CREATE INDEX IF NOT EXISTS idx_runs_ticket ON runs(ticket_id);
    """

    ACTIVE_STATES = ("Claimed", "Running", "SpikeResultReady")
    DURABLE_INDEX_STATES = (VERIFICATION_BLOCKED_RUN_STATE,)
    # Completed entries linger in the runs-index file this long after `ended_at`
    # so the board can render review-pending pills across the typical merge gap
    # without flicker, then get pruned.
    INDEX_RETENTION_SECONDS = 300

    def __init__(self, path: Path, index_path: Path | None = None):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # Ephemeral live-state view consumed by the board overlay. None disables
        # index writes (keeps the store usable in unit tests without a filesystem
        # side effect).
        self.index_path = index_path
        self._lock = threading.Lock()
        self._init()

    @contextmanager
    def _conn(self):
        with self._lock:
            conn = sqlite3.connect(str(self.path), isolation_level=None)
            conn.row_factory = sqlite3.Row
            try:
                yield conn
            finally:
                conn.close()

    def _init(self) -> None:
        # PRAGMA user_version gates schema migrations. A version mismatch
        # drops the table entirely (historical runs lose their rows —
        # acceptable for a local dev tool).
        with self._conn() as c:
            current = int(c.execute("PRAGMA user_version").fetchone()[0])
            if current == 4:
                c.execute(
                    "ALTER TABLE runs ADD COLUMN execution_mode TEXT NOT NULL "
                    "DEFAULT 'implementation'"
                )
                c.execute(f"PRAGMA user_version = {self.SCHEMA_VERSION}")
                c.executescript(self.SCHEMA)
            elif current != self.SCHEMA_VERSION:
                c.execute("DROP TABLE IF EXISTS runs")
                c.executescript(self.SCHEMA)
                c.execute(f"PRAGMA user_version = {self.SCHEMA_VERSION}")
            else:
                c.executescript(self.SCHEMA)

    def insert(self, *, ticket_id: str, repo_path: str, workspace_path: str,
               branch: str, state: str, execution_mode: str = "implementation",
               attempt: int = 1, log_path: str | None = None,
               provider_key: str | None = None, model_alias: str | None = None,
               worker_model: str | None = None, worker_effort: str | None = None,
               worker_sizing_rationale: str | None = None,
               worker_provider_notes: str | None = None) -> int:
        with self._conn() as c:
            cur = c.execute(
                "INSERT INTO runs(ticket_id, repo_path, workspace_path, branch, execution_mode, "
                "state, attempt, started_at, log_path, provider_key, model_alias, "
                "worker_model, worker_effort, worker_sizing_rationale, worker_provider_notes) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (ticket_id, repo_path, workspace_path, branch, _execution_mode(execution_mode),
                 state, attempt, time.time(), log_path, provider_key, model_alias,
                 worker_model, worker_effort, worker_sizing_rationale, worker_provider_notes),
            )
            run_id = int(cur.lastrowid)
        self.write_index()
        return run_id

    def insert_reconciled(
        self,
        *,
        run_id: int,
        ticket_id: str,
        repo_path: str,
        state: str,
        attempt: int = 1,
        last_error: str | None = None,
    ) -> dict[str, Any]:
        """Restore one terminal run identity whose canonical ticket survived.

        Callers must validate the committed ticket before using this method. It
        never overwrites an existing ledger row and never invents a live
        worktree or branch for preserved historical evidence.
        """
        if run_id <= 0:
            raise ValueError("run_id must be positive")
        if attempt <= 0:
            raise ValueError("attempt must be positive")
        now = time.time()
        with self._conn() as c:
            if c.execute("SELECT 1 FROM runs WHERE id = ?", (run_id,)).fetchone():
                raise ValueError(f"run {run_id} already exists")
            c.execute(
                "INSERT INTO runs(id, ticket_id, repo_path, workspace_path, branch, "
                "state, attempt, started_at, ended_at, exit_code, last_error, activity, "
                "activity_at) VALUES (?, ?, ?, '', ?, ?, ?, ?, ?, 0, ?, ?, ?)",
                (
                    run_id,
                    ticket_id,
                    repo_path,
                    f"preserved/{sanitize_identifier(ticket_id)}",
                    state,
                    attempt,
                    now,
                    now,
                    last_error,
                    "Reconciled from committed canonical ticket evidence",
                    now,
                ),
            )
            row = c.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
            reconciled = dict(row)
        self.write_index()
        return reconciled

    def update(self, run_id: int, *, state: str | None = None, pid: int | None = None,
               exit_code: int | None = None, last_error: str | None = None,
               ended: bool = False) -> None:
        fields, values = [], []
        if state is not None:
            fields.append("state = ?"); values.append(state)
        if pid is not None:
            fields.append("pid = ?"); values.append(pid)
        if exit_code is not None:
            fields.append("exit_code = ?"); values.append(exit_code)
        if last_error is not None:
            fields.append("last_error = ?"); values.append(last_error)
        if ended:
            fields.append("ended_at = ?"); values.append(time.time())
        if not fields:
            return
        values.append(run_id)
        with self._conn() as c:
            c.execute(f"UPDATE runs SET {', '.join(fields)} WHERE id = ?", values)
        self.write_index()

    def set_activity(self, run_id: int, activity: str) -> None:
        """Record the worker's current activity summary (RR-12) and refresh its
        timestamp. Rewrites the index so the board picks it up within a poll."""
        with self._conn() as c:
            c.execute("UPDATE runs SET activity = ?, activity_at = ? WHERE id = ?",
                      (activity, time.time(), run_id))
        self.write_index()

    def touch_activity(self, run_id: int) -> None:
        """Bump only the activity timestamp — the heartbeat while a tool is in
        flight, so a long operation doesn't read as stalled on the board."""
        with self._conn() as c:
            c.execute("UPDATE runs SET activity_at = ? WHERE id = ?",
                      (time.time(), run_id))
        self.write_index()

    def get(self, run_id: int) -> dict | None:
        with self._conn() as c:
            row = c.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
            return dict(row) if row else None

    def list(self, state: str | None = None, limit: int = 100) -> list[dict]:
        with self._conn() as c:
            if state:
                rows = c.execute(
                    "SELECT * FROM runs WHERE state = ? ORDER BY id DESC LIMIT ?",
                    (state, limit),
                ).fetchall()
            else:
                rows = c.execute(
                    "SELECT * FROM runs ORDER BY id DESC LIMIT ?", (limit,)
                ).fetchall()
            return [dict(r) for r in rows]

    def list_for_repo(self, repo_path: str, *, limit: int = 1000) -> list[dict]:
        repo = str(Path(repo_path).expanduser().resolve())
        with self._conn() as c:
            rows = c.execute(
                "SELECT * FROM runs WHERE repo_path = ? ORDER BY id DESC LIMIT ?",
                (repo, max(1, int(limit))),
            ).fetchall()
            return [dict(r) for r in rows]

    def active_count(self, repo_path: str | None = None) -> int:
        placeholders = ",".join("?" * len(self.ACTIVE_STATES))
        params: list[Any] = [*self.ACTIVE_STATES]
        repo_clause = ""
        if repo_path is not None:
            repo_clause = "AND repo_path = ? "
            params.append(str(Path(repo_path).expanduser().resolve()))
        with self._conn() as c:
            row = c.execute(
                f"SELECT COUNT(*) AS count FROM runs WHERE state IN ({placeholders}) {repo_clause}",
                params,
            ).fetchone()
            return int(row["count"] or 0)

    def find_active(self, ticket_id: str, repo_path: str | None = None) -> dict | None:
        ph = ",".join("?" * len(self.ACTIVE_STATES))
        params: list[Any] = [ticket_id, *self.ACTIVE_STATES]
        repo_clause = ""
        if repo_path is not None:
            repo_clause = "AND repo_path = ? "
            params.append(str(Path(repo_path).expanduser().resolve()))
        with self._conn() as c:
            row = c.execute(
                f"SELECT * FROM runs WHERE ticket_id = ? AND state IN ({ph}) "
                f"{repo_clause}"
                "ORDER BY id DESC LIMIT 1",
                params,
            ).fetchone()
            return dict(row) if row else None

    def find_awaiting_merge(self, ticket_id: str, repo_path: str | None = None) -> dict | None:
        params: list[Any] = [ticket_id, *REVIEW_BLOCKING_STATES]
        placeholders = ",".join("?" * len(REVIEW_BLOCKING_STATES))
        repo_clause = ""
        if repo_path is not None:
            repo_clause = "AND repo_path = ? "
            params.append(str(Path(repo_path).expanduser().resolve()))
        with self._conn() as c:
            row = c.execute(
                f"SELECT * FROM runs WHERE ticket_id = ? AND state IN ({placeholders}) "
                f"{repo_clause}"
                "ORDER BY id DESC LIMIT 1",
                params,
            ).fetchone()
            return dict(row) if row else None

    def reconcile_on_startup(self) -> int:
        """Recover abandoned runs while preserving worker processes still alive."""
        ph = ",".join("?" * len(self.ACTIVE_STATES))
        with self._conn() as c:
            rows = c.execute(
                f"SELECT id, pid, execution_mode FROM runs WHERE state IN ({ph})",
                self.ACTIVE_STATES,
            ).fetchall()
            abandoned = [
                int(row["id"])
                for row in rows
                if row["execution_mode"] == SPIKE_EXECUTION_MODE
                or not _process_is_alive(row["pid"])
            ]
            for row in rows:
                if row["execution_mode"] != SPIKE_EXECUTION_MODE or int(row["id"]) not in abandoned:
                    continue
                try:
                    os.kill(int(row["pid"]), signal.SIGTERM)
                except (OSError, TypeError, ValueError):
                    pass
            if not abandoned:
                return 0
            placeholders = ",".join("?" * len(abandoned))
            c.execute(
                f"UPDATE runs SET state = 'Stalled', ended_at = ?, "
                "last_error = CASE WHEN execution_mode = 'spike' "
                "THEN 'Spike stopped during daemon restart; retry is available' "
                "ELSE 'Worker process was no longer running when daemon restarted' END "
                f"WHERE id IN ({placeholders})",
                (time.time(), *abandoned),
            )
            return len(abandoned)

    def next_attempt(self, ticket_id: str, repo_path: str | None = None) -> int:
        """Returns the attempt number to use for a new run on this ticket (1 if none, max+1 otherwise)."""
        params: list[Any] = [ticket_id]
        repo_clause = ""
        if repo_path is not None:
            repo_clause = "AND repo_path = ? "
            params.append(str(Path(repo_path).expanduser().resolve()))
        with self._conn() as c:
            row = c.execute(
                f"SELECT MAX(attempt) AS a FROM runs WHERE ticket_id = ? {repo_clause}",
                params,
            ).fetchone()
            if row and row["a"]:
                return int(row["a"]) + 1
            return 1

    def recent_for_ticket(
        self,
        ticket_id: str,
        repo_path: str | None = None,
        *,
        limit: int = 10,
    ) -> list[dict]:
        params: list[Any] = [ticket_id]
        repo_clause = ""
        if repo_path is not None:
            repo_clause = "AND repo_path = ? "
            params.append(str(Path(repo_path).expanduser().resolve()))
        params.append(max(1, int(limit)))
        with self._conn() as c:
            rows = c.execute(
                f"SELECT * FROM runs WHERE ticket_id = ? {repo_clause}"
                "ORDER BY attempt DESC, id DESC LIMIT ?",
                params,
            ).fetchall()
            return [dict(r) for r in rows]

    # -- runs-index file (board live-state view) --------------------------

    def _index_entries(self, conn) -> list[dict]:
        """Active runs plus completed ones inside the retention window. One
        entry per run, shaped for the board overlay (run_id is the row id)."""
        cutoff = time.time() - self.INDEX_RETENTION_SECONDS
        review_placeholders = ",".join("?" * len(REVIEW_BLOCKING_STATES))
        durable_placeholders = ",".join("?" * len(self.DURABLE_INDEX_STATES))
        rows = conn.execute(
            "SELECT * FROM runs WHERE ended_at IS NULL OR ended_at >= ? "
            f"OR state IN ({review_placeholders}) "
            f"OR state IN ({durable_placeholders}) "
            "ORDER BY id DESC",
            (cutoff, *REVIEW_BLOCKING_STATES, *self.DURABLE_INDEX_STATES),
        ).fetchall()
        return [
            {
                "ticket_id": r["ticket_id"],
                "repo_path": r["repo_path"],
                "run_id": r["id"],
                "state": r["state"],
                "attempt": r["attempt"],
                "started_at": r["started_at"],
                "ended_at": r["ended_at"],
                "last_error": r["last_error"],
                "workspace_path": r["workspace_path"],
                "branch": r["branch"],
                "execution_mode": r["execution_mode"],
                "activity": r["activity"],
                "activity_at": r["activity_at"],
                "provider_key": r["provider_key"],
                "model_alias": r["model_alias"],
                "worker_model": r["worker_model"],
                "worker_effort": r["worker_effort"],
                "worker_sizing_rationale": r["worker_sizing_rationale"],
                "worker_provider_notes": r["worker_provider_notes"],
            }
            for r in rows
        ]

    def write_index(self) -> None:
        """Rewrite the runs-index file from current state. Called on every
        transition (insert/update) so the file never lags SQLite, and on a
        periodic sweep so completed entries get pruned once their retention
        window lapses. Atomic temp-write + rename so the board never reads a
        half-written file. No-op when index_path is unset."""
        if self.index_path is None:
            return
        with self._conn() as c:
            entries = self._index_entries(c)
        payload = json.dumps({"runs": entries}, default=str, indent=2)
        tmp = self.index_path.with_name(self.index_path.name + ".tmp")
        try:
            tmp.write_text(payload)
            tmp.replace(self.index_path)
        except OSError as e:
            print(f"[orchestrator] could not write runs index {self.index_path}: {e}",
                  file=sys.stderr)


class OrchestratorSessionStore:
    """Durable foreground-orchestrator lifecycle records.

    These rows describe the persistent per-project/session orchestrator owned by
    the bridge/frontstage loop. They do not spawn or hold a model process; idle
    means durable state only, so keeping a session alive does not spend tokens.
    """

    SCHEMA_VERSION = 1

    SCHEMA = """
    CREATE TABLE IF NOT EXISTS orchestrator_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_key TEXT NOT NULL UNIQUE,
        repo_path TEXT NOT NULL,
        provider_key TEXT NOT NULL,
        model_alias TEXT,
        effort TEXT,
        state TEXT NOT NULL,
        started_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        heartbeat_at REAL NOT NULL,
        stopped_at REAL,
        stop_reason TEXT,
        pid INTEGER,
        source TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_orchestrator_sessions_repo ON orchestrator_sessions(repo_path);
    CREATE INDEX IF NOT EXISTS idx_orchestrator_sessions_state ON orchestrator_sessions(state);
    """

    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._init()

    @contextmanager
    def _conn(self):
        with self._lock:
            conn = sqlite3.connect(str(self.path), isolation_level=None)
            conn.row_factory = sqlite3.Row
            try:
                yield conn
            finally:
                conn.close()

    def _init(self) -> None:
        with self._conn() as c:
            current = int(c.execute("PRAGMA user_version").fetchone()[0])
            if current != self.SCHEMA_VERSION:
                c.execute("DROP TABLE IF EXISTS orchestrator_sessions")
                c.executescript(self.SCHEMA)
                c.execute(f"PRAGMA user_version = {self.SCHEMA_VERSION}")
            else:
                c.executescript(self.SCHEMA)

    @staticmethod
    def session_key(repo_path: str) -> str:
        repo = str(Path(repo_path).expanduser().resolve())
        digest = hashlib.sha1(repo.encode("utf-8")).hexdigest()[:16]
        return f"project:{digest}"

    @staticmethod
    def _normalize_provider(provider_key: str | None) -> str:
        provider = (provider_key or "codex").strip().lower()
        return "claude" if "claude" in provider else "codex"

    @staticmethod
    def _normalize_state(state: str | None) -> str:
        value = (state or "idle").strip().lower()
        if value not in ORCHESTRATOR_SESSION_STATES:
            raise ValueError(
                "invalid orchestrator state "
                f"{state!r}; expected one of {', '.join(sorted(ORCHESTRATOR_SESSION_STATES))}"
            )
        return value

    def ensure(
        self,
        *,
        repo_path: str,
        provider_key: str,
        model_alias: str | None = None,
        effort: str | None = None,
        source: str | None = None,
        pid: int | None = None,
        state: str = "idle",
    ) -> dict[str, Any]:
        repo = str(Path(repo_path).expanduser().resolve())
        key = self.session_key(repo)
        provider = self._normalize_provider(provider_key)
        next_state = self._normalize_state(state)
        now = time.time()
        with self._conn() as c:
            row = c.execute(
                "SELECT * FROM orchestrator_sessions WHERE session_key = ?",
                (key,),
            ).fetchone()
            if row is None:
                cur = c.execute(
                    "INSERT INTO orchestrator_sessions("
                    "session_key, repo_path, provider_key, model_alias, effort, state, "
                    "started_at, updated_at, heartbeat_at, pid, source"
                    ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        key,
                        repo,
                        provider,
                        model_alias,
                        effort,
                        next_state,
                        now,
                        now,
                        now,
                        pid,
                        source,
                    ),
                )
                new_row = c.execute(
                    "SELECT * FROM orchestrator_sessions WHERE id = ?",
                    (cur.lastrowid,),
                ).fetchone()
                result = dict(new_row)
                result["created"] = True
                result["provider_changed"] = False
                return result

            provider_changed = row["provider_key"] != provider
            stop_reason = (
                f"provider changed from {row['provider_key']} to {provider}"
                if provider_changed else None
            )
            c.execute(
                "UPDATE orchestrator_sessions SET "
                "repo_path = ?, provider_key = ?, model_alias = ?, effort = ?, "
                "state = ?, updated_at = ?, heartbeat_at = ?, stopped_at = NULL, "
                "stop_reason = ?, pid = ?, source = ? "
                "WHERE id = ?",
                (
                    repo,
                    provider,
                    model_alias,
                    effort,
                    next_state,
                    now,
                    now,
                    stop_reason,
                    pid,
                    source,
                    row["id"],
                ),
            )
            new_row = c.execute(
                "SELECT * FROM orchestrator_sessions WHERE id = ?",
                (row["id"],),
            ).fetchone()
            result = dict(new_row)
            result["created"] = False
            result["provider_changed"] = provider_changed
            return result

    def heartbeat(
        self,
        *,
        session_id: int | None = None,
        repo_path: str | None = None,
        provider_key: str | None = None,
        state: str | None = None,
    ) -> dict[str, Any] | None:
        now = time.time()
        next_state = self._normalize_state(state) if state is not None else None
        with self._conn() as c:
            row = self._find_row(c, session_id=session_id, repo_path=repo_path)
            if row is None:
                return None
            provider = self._normalize_provider(provider_key) if provider_key else row["provider_key"]
            fields = [
                "heartbeat_at = ?",
                "updated_at = ?",
                "provider_key = ?",
                "stopped_at = NULL",
                "stop_reason = NULL",
            ]
            values: list[Any] = [now, now, provider]
            if next_state is not None:
                fields.append("state = ?")
                values.append(next_state)
            elif row["state"] in ("stale", "stopped", "failed"):
                fields.append("state = ?")
                values.append("idle")
            values.append(row["id"])
            c.execute(
                f"UPDATE orchestrator_sessions SET {', '.join(fields)} WHERE id = ?",
                values,
            )
            updated = c.execute(
                "SELECT * FROM orchestrator_sessions WHERE id = ?",
                (row["id"],),
            ).fetchone()
            return dict(updated) if updated else None

    def stop(
        self,
        *,
        session_id: int | None = None,
        repo_path: str | None = None,
        reason: str | None = None,
    ) -> dict[str, Any] | None:
        now = time.time()
        with self._conn() as c:
            row = self._find_row(c, session_id=session_id, repo_path=repo_path)
            if row is None:
                return None
            c.execute(
                "UPDATE orchestrator_sessions SET state = 'stopped', updated_at = ?, "
                "stopped_at = ?, stop_reason = ? WHERE id = ?",
                (now, now, reason, row["id"]),
            )
            updated = c.execute(
                "SELECT * FROM orchestrator_sessions WHERE id = ?",
                (row["id"],),
            ).fetchone()
            return dict(updated) if updated else None

    def reconcile_stale(self, stale_after_seconds: float = ORCHESTRATOR_SESSION_STALE_AFTER_SECONDS) -> int:
        cutoff = time.time() - max(0.0, stale_after_seconds)
        with self._conn() as c:
            cur = c.execute(
                "UPDATE orchestrator_sessions SET state = 'stale', updated_at = ?, "
                "stop_reason = 'heartbeat expired' "
                "WHERE state NOT IN ('stopped', 'stale') AND heartbeat_at < ?",
                (time.time(), cutoff),
            )
            return cur.rowcount

    def get(self, session_id: int) -> dict[str, Any] | None:
        with self._conn() as c:
            row = c.execute(
                "SELECT * FROM orchestrator_sessions WHERE id = ?",
                (session_id,),
            ).fetchone()
            return dict(row) if row else None

    def list(self, *, repo_path: str | None = None, limit: int = 100) -> list[dict[str, Any]]:
        self.reconcile_stale()
        with self._conn() as c:
            if repo_path:
                repo = str(Path(repo_path).expanduser().resolve())
                rows = c.execute(
                    "SELECT * FROM orchestrator_sessions WHERE repo_path = ? "
                    "ORDER BY updated_at DESC LIMIT ?",
                    (repo, limit),
                ).fetchall()
            else:
                rows = c.execute(
                    "SELECT * FROM orchestrator_sessions ORDER BY updated_at DESC LIMIT ?",
                    (limit,),
                ).fetchall()
            return [dict(r) for r in rows]

    def _find_row(
        self,
        conn: sqlite3.Connection,
        *,
        session_id: int | None = None,
        repo_path: str | None = None,
    ) -> sqlite3.Row | None:
        if session_id is not None:
            return conn.execute(
                "SELECT * FROM orchestrator_sessions WHERE id = ?",
                (session_id,),
            ).fetchone()
        if repo_path:
            key = self.session_key(str(Path(repo_path).expanduser().resolve()))
            return conn.execute(
                "SELECT * FROM orchestrator_sessions WHERE session_key = ?",
                (key,),
            ).fetchone()
        return None


class OrchestratorCommandStore:
    """Private raw-command inbox for the persistent orchestrator."""

    SCHEMA_VERSION = 4

    SCHEMA = """
    CREATE TABLE IF NOT EXISTS orchestrator_commands (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        intent_id TEXT NOT NULL UNIQUE,
        relay_command_id TEXT NOT NULL,
        relay_command_seq INTEGER NOT NULL,
        within_turn_order INTEGER NOT NULL DEFAULT 1,
        session_id INTEGER,
        repo_path TEXT NOT NULL,
        provider_key TEXT,
        source_text TEXT NOT NULL,
        context TEXT,
        action TEXT,
        outcome TEXT,
        ticket_id TEXT,
        target TEXT,
        disposition TEXT,
        cancellation_scope TEXT NOT NULL DEFAULT 'none',
        lifecycle_state TEXT NOT NULL DEFAULT 'recognized',
        status TEXT NOT NULL,
        status_message TEXT,
        error TEXT,
        received_at REAL,
        processed_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_orchestrator_commands_repo ON orchestrator_commands(repo_path);
    CREATE INDEX IF NOT EXISTS idx_orchestrator_commands_status ON orchestrator_commands(status);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_orchestrator_commands_turn_order
        ON orchestrator_commands(relay_command_id, within_turn_order);
    """

    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._init()

    @contextmanager
    def _conn(self):
        with self._lock:
            conn = sqlite3.connect(str(self.path), isolation_level=None)
            conn.row_factory = sqlite3.Row
            try:
                yield conn
            finally:
                conn.close()

    def _init(self) -> None:
        with self._conn() as c:
            current = int(c.execute("PRAGMA user_version").fetchone()[0])
            if current == 0:
                c.executescript(self.SCHEMA)
                c.execute(f"PRAGMA user_version = {self.SCHEMA_VERSION}")
                return
            if current in {1, 2, 3}:
                existing_columns = {
                    str(row["name"])
                    for row in c.execute("PRAGMA table_info(orchestrator_commands)").fetchall()
                }
                migrations = {
                    "ticket_id": "TEXT",
                    "status_message": "TEXT",
                    "error": "TEXT",
                    "processed_at": "REAL",
                    "context": "TEXT",
                }
                for name, declaration in migrations.items():
                    if name not in existing_columns:
                        c.execute(f"ALTER TABLE orchestrator_commands ADD COLUMN {name} {declaration}")
                c.execute("ALTER TABLE orchestrator_commands RENAME TO orchestrator_commands_legacy")
                c.executescript(self.SCHEMA)
                c.execute(
                    "INSERT INTO orchestrator_commands("
                    "intent_id, relay_command_id, relay_command_seq, within_turn_order, "
                    "session_id, repo_path, provider_key, source_text, context, action, outcome, "
                    "ticket_id, target, disposition, cancellation_scope, lifecycle_state, status, "
                    "status_message, error, received_at, processed_at, created_at, updated_at"
                    ") SELECT relay_command_id, relay_command_id, relay_command_seq, 1, "
                    "session_id, repo_path, provider_key, source_text, context, action, outcome, "
                    "ticket_id, NULL, NULL, 'none', 'recognized', status, status_message, error, "
                    "received_at, processed_at, created_at, updated_at "
                    "FROM orchestrator_commands_legacy"
                )
                c.execute("DROP TABLE orchestrator_commands_legacy")
                c.executescript(self.SCHEMA)
                c.execute(f"PRAGMA user_version = {self.SCHEMA_VERSION}")
                return
            if current == self.SCHEMA_VERSION:
                c.executescript(self.SCHEMA)
                return
            raise RuntimeError(
                f"unsupported orchestrator_commands schema version {current}; "
                f"expected <= {self.SCHEMA_VERSION}"
            )

    @staticmethod
    def _public_row(row: sqlite3.Row | dict[str, Any]) -> dict[str, Any]:
        data = dict(row)
        data.pop("source_text", None)
        data.pop("context", None)
        return data

    def record(
        self,
        *,
        repo_path: str,
        source_text: str,
        relay_command_seq: int | str,
        relay_command_id: str,
        intent_id: str | None = None,
        within_turn_order: int | str | None = None,
        session_id: int | None = None,
        provider_key: str | None = None,
        context: str | None = None,
        action: str | None = None,
        outcome: str | None = None,
        target: str | None = None,
        disposition: str | None = None,
        cancellation_scope: str | None = None,
        lifecycle_state: str | None = None,
        received_at: float | None = None,
        status: str = "received",
    ) -> dict[str, Any]:
        if not str(source_text or "").strip():
            raise ValueError("source_text is required")
        command_id = str(relay_command_id or "").strip()
        if not command_id:
            raise ValueError("relay_command_id is required")
        item_id = str(intent_id or command_id).strip()
        if not item_id:
            raise ValueError("intent_id is required")
        try:
            command_seq = int(relay_command_seq)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"invalid relay_command_seq: {relay_command_seq!r}") from exc
        command_status = str(status or "received").strip().lower()
        if command_status not in ORCHESTRATOR_COMMAND_STATUSES:
            raise ValueError(
                "invalid orchestrator command status "
                f"{status!r}; expected one of {', '.join(sorted(ORCHESTRATOR_COMMAND_STATUSES))}"
            )
        repo = str(Path(repo_path).expanduser().resolve())
        now = time.time()
        provider = OrchestratorSessionStore._normalize_provider(provider_key) if provider_key else None
        refined_context = _clean_optional_multiline_text(context)
        try:
            item_order = max(1, int(within_turn_order or 1))
        except (TypeError, ValueError) as exc:
            raise ValueError(f"invalid within_turn_order: {within_turn_order!r}") from exc
        with self._conn() as c:
            existing = c.execute(
                "SELECT * FROM orchestrator_commands WHERE intent_id = ?",
                (item_id,),
            ).fetchone()
            if existing is not None and existing["status"] in ORCHESTRATOR_COMMAND_TERMINAL_STATUSES:
                return self._public_row(existing)

            c.execute(
                "INSERT INTO orchestrator_commands("
                "intent_id, relay_command_id, relay_command_seq, within_turn_order, session_id, "
                "repo_path, provider_key, source_text, context, action, outcome, ticket_id, "
                "target, disposition, cancellation_scope, lifecycle_state, status, status_message, "
                "error, received_at, processed_at, created_at, updated_at"
                ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(intent_id) DO UPDATE SET "
                "relay_command_seq = excluded.relay_command_seq, "
                "within_turn_order = excluded.within_turn_order, "
                "session_id = excluded.session_id, "
                "repo_path = excluded.repo_path, "
                "provider_key = excluded.provider_key, "
                "source_text = excluded.source_text, "
                "context = excluded.context, "
                "action = excluded.action, "
                "outcome = excluded.outcome, "
                "ticket_id = excluded.ticket_id, "
                "target = excluded.target, "
                "disposition = excluded.disposition, "
                "cancellation_scope = excluded.cancellation_scope, "
                "lifecycle_state = excluded.lifecycle_state, "
                "status = excluded.status, "
                "status_message = excluded.status_message, "
                "error = excluded.error, "
                "received_at = excluded.received_at, "
                "processed_at = excluded.processed_at, "
                "updated_at = excluded.updated_at",
                (
                    item_id,
                    command_id,
                    command_seq,
                    item_order,
                    session_id,
                    repo,
                    provider,
                    source_text,
                    refined_context,
                    action,
                    outcome,
                    None,
                    target,
                    disposition,
                    str(cancellation_scope or "none"),
                    str(lifecycle_state or "recognized"),
                    command_status,
                    None,
                    None,
                    received_at,
                    None,
                    now,
                    now,
                ),
            )
            row = c.execute(
                "SELECT * FROM orchestrator_commands WHERE intent_id = ?",
                (item_id,),
            ).fetchone()
            return self._public_row(row)

    def update_status(
        self,
        command_id: str,
        *,
        intent_id: str | None = None,
        status: str,
        action: str | None = None,
        outcome: str | None = None,
        ticket_id: str | None = None,
        status_message: str | None = None,
        error: str | None = None,
    ) -> dict[str, Any] | None:
        command_status = str(status or "").strip().lower()
        if command_status not in ORCHESTRATOR_COMMAND_STATUSES:
            raise ValueError(
                "invalid orchestrator command status "
                f"{status!r}; expected one of {', '.join(sorted(ORCHESTRATOR_COMMAND_STATUSES))}"
            )
        now = time.time()
        processed_at = now if command_status in ORCHESTRATOR_COMMAND_TERMINAL_STATUSES else None
        fields = ["status = ?", "updated_at = ?"]
        values: list[Any] = [command_status, now]
        if processed_at is not None:
            fields.append("processed_at = ?")
            values.append(processed_at)
        if action is not None:
            fields.append("action = ?")
            values.append(action)
        if outcome is not None:
            fields.append("outcome = ?")
            values.append(outcome)
        if ticket_id is not None:
            fields.append("ticket_id = ?")
            values.append(ticket_id)
        if status_message is not None:
            fields.append("status_message = ?")
            values.append(status_message)
        if error is not None:
            fields.append("error = ?")
            values.append(error)
        identity_column = "intent_id" if intent_id else "relay_command_id"
        identity_value = str(intent_id or command_id)
        values.append(identity_value)
        with self._conn() as c:
            c.execute(
                f"UPDATE orchestrator_commands SET {', '.join(fields)} WHERE {identity_column} = ?",
                values,
            )
            row = c.execute(
                f"SELECT * FROM orchestrator_commands WHERE {identity_column} = ? "
                "ORDER BY within_turn_order DESC, id DESC LIMIT 1",
                (identity_value,),
            ).fetchone()
            return self._public_row(row) if row else None

    def get_private(self, command_id: str, *, intent_id: str | None = None) -> dict[str, Any] | None:
        identity_column = "intent_id" if intent_id else "relay_command_id"
        identity_value = str(intent_id or command_id)
        with self._conn() as c:
            row = c.execute(
                f"SELECT * FROM orchestrator_commands WHERE {identity_column} = ? "
                "ORDER BY within_turn_order DESC, id DESC LIMIT 1",
                (identity_value,),
            ).fetchone()
            return dict(row) if row else None

    def get_public(self, command_id: str, *, intent_id: str | None = None) -> dict[str, Any] | None:
        identity_column = "intent_id" if intent_id else "relay_command_id"
        identity_value = str(intent_id or command_id)
        with self._conn() as c:
            row = c.execute(
                f"SELECT * FROM orchestrator_commands WHERE {identity_column} = ? "
                "ORDER BY within_turn_order DESC, id DESC LIMIT 1",
                (identity_value,),
            ).fetchone()
            return self._public_row(row) if row else None

    def pending(self, *, repo_path: str | None = None, limit: int = 20) -> list[dict[str, Any]]:
        params: list[Any] = ["received"]
        repo_clause = ""
        if repo_path:
            repo_clause = "AND repo_path = ? "
            params.append(str(Path(repo_path).expanduser().resolve()))
        params.append(max(1, int(limit)))
        with self._conn() as c:
            rows = c.execute(
                "SELECT * FROM orchestrator_commands WHERE status = ? "
                f"{repo_clause}"
                "ORDER BY relay_command_seq ASC, within_turn_order ASC, id ASC LIMIT ?",
                params,
            ).fetchall()
            return [dict(row) for row in rows]

    def recoverable(
        self,
        *,
        repo_path: str | None = None,
        limit: int = 20,
    ) -> list[dict[str, Any]]:
        statuses = ("queued", "claimed", "mutation_authorized", "delivery_failed", "clarification_required")
        placeholders = ",".join("?" * len(statuses))
        params: list[Any] = [*statuses]
        repo_clause = ""
        if repo_path:
            repo_clause = "AND repo_path = ? "
            params.append(str(Path(repo_path).expanduser().resolve()))
        params.append(max(1, int(limit)))
        with self._conn() as c:
            rows = c.execute(
                f"SELECT * FROM orchestrator_commands WHERE status IN ({placeholders}) "
                f"{repo_clause}"
                "ORDER BY relay_command_seq ASC, within_turn_order ASC, id ASC LIMIT ?",
                params,
            ).fetchall()
            return [self._public_row(row) for row in rows]


class MessengerOutcomeStore:
    """Durable, bounded queue of public worker outcomes for the voice messenger."""

    SCHEMA_VERSION = 1
    MAX_PENDING_PER_REPO = 50

    SCHEMA = """
    CREATE TABLE IF NOT EXISTS messenger_outcomes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_key TEXT NOT NULL UNIQUE,
        repo_path TEXT NOT NULL,
        provider_key TEXT,
        kind TEXT NOT NULL,
        ticket_id TEXT,
        run_id INTEGER,
        message TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        delivered_at REAL,
        delivery_attempts INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_messenger_outcomes_repo_pending
        ON messenger_outcomes(repo_path, delivered_at, id);
    """

    def __init__(self, path: Path, *, max_pending_per_repo: int = MAX_PENDING_PER_REPO):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.max_pending_per_repo = max(1, int(max_pending_per_repo))
        self._lock = threading.Lock()
        self._init()

    @contextmanager
    def _conn(self):
        with self._lock:
            conn = sqlite3.connect(str(self.path), isolation_level=None)
            conn.row_factory = sqlite3.Row
            try:
                yield conn
            finally:
                conn.close()

    def _init(self) -> None:
        with self._conn() as c:
            current = int(c.execute("PRAGMA user_version").fetchone()[0])
            if current != self.SCHEMA_VERSION:
                c.execute("DROP TABLE IF EXISTS messenger_outcomes")
                c.executescript(self.SCHEMA)
                c.execute(f"PRAGMA user_version = {self.SCHEMA_VERSION}")
            else:
                c.executescript(self.SCHEMA)

    @staticmethod
    def event_key(
        *,
        repo_path: str,
        kind: str,
        ticket_id: str | None,
        run_id: int | None,
        source: str | None,
    ) -> str:
        repo = str(Path(repo_path).expanduser().resolve())
        return "|".join([
            repo,
            str(kind or "").strip().lower(),
            str(ticket_id or "").strip().upper(),
            str(run_id or ""),
            str(source or "").strip().lower(),
        ])

    def record(
        self,
        *,
        repo_path: str,
        payload: dict[str, Any],
        provider_key: str | None = None,
    ) -> dict[str, Any] | None:
        trace = payload.get("trace_event")
        if not isinstance(trace, dict):
            return None
        kind = str(trace.get("kind") or "").strip().lower()
        message = str(trace.get("message") or payload.get("text") or "").strip()
        if not kind or not message:
            return None
        repo = str(Path(repo_path).expanduser().resolve())
        ticket_id = str(trace.get("ticket_id") or "").strip().upper() or None
        raw_run_id = trace.get("run_id")
        try:
            run_id = int(raw_run_id) if raw_run_id is not None else None
        except (TypeError, ValueError):
            run_id = None
        source = str(trace.get("source") or "").strip().lower() or None
        key = self.event_key(
            repo_path=repo,
            kind=kind,
            ticket_id=ticket_id,
            run_id=run_id,
            source=source,
        )
        now = time.time()
        payload_json = json.dumps(payload, sort_keys=True)
        provider = OrchestratorSessionStore._normalize_provider(provider_key) if provider_key else None
        with self._conn() as c:
            c.execute(
                "INSERT OR IGNORE INTO messenger_outcomes("
                "event_key, repo_path, provider_key, kind, ticket_id, run_id, message, "
                "payload_json, created_at"
                ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (key, repo, provider, kind, ticket_id, run_id, message, payload_json, now),
            )
            self._prune_locked(c, repo)
            row = c.execute(
                "SELECT * FROM messenger_outcomes WHERE event_key = ?",
                (key,),
            ).fetchone()
            return self._public_row(row) if row else None

    def pending(
        self,
        *,
        repo_path: str | None = None,
        provider_key: str | None = None,
        limit: int = 20,
    ) -> list[dict[str, Any]]:
        del provider_key
        params: list[Any] = []
        clauses = ["delivered_at IS NULL"]
        if repo_path:
            clauses.append("repo_path = ?")
            params.append(str(Path(repo_path).expanduser().resolve()))
        params.append(max(1, int(limit)))
        with self._conn() as c:
            rows = c.execute(
                "SELECT * FROM messenger_outcomes "
                f"WHERE {' AND '.join(clauses)} "
                "ORDER BY id ASC LIMIT ?",
                params,
            ).fetchall()
            return [self._public_row(row) for row in rows]

    def mark_delivered(self, outcome_id: int) -> dict[str, Any] | None:
        now = time.time()
        with self._conn() as c:
            c.execute(
                "UPDATE messenger_outcomes SET delivered_at = ?, "
                "delivery_attempts = delivery_attempts + 1 "
                "WHERE id = ? AND delivered_at IS NULL",
                (now, int(outcome_id)),
            )
            row = c.execute(
                "SELECT * FROM messenger_outcomes WHERE id = ?",
                (int(outcome_id),),
            ).fetchone()
            return self._public_row(row) if row else None

    def record_attempt(self, outcome_id: int) -> None:
        with self._conn() as c:
            c.execute(
                "UPDATE messenger_outcomes SET delivery_attempts = delivery_attempts + 1 "
                "WHERE id = ? AND delivered_at IS NULL",
                (int(outcome_id),),
            )

    def _prune_locked(self, conn: sqlite3.Connection, repo_path: str) -> None:
        conn.execute(
            "DELETE FROM messenger_outcomes "
            "WHERE repo_path = ? AND delivered_at IS NULL AND id NOT IN ("
            "SELECT id FROM messenger_outcomes "
            "WHERE repo_path = ? AND delivered_at IS NULL "
            "ORDER BY id DESC LIMIT ?"
            ")",
            (repo_path, repo_path, self.max_pending_per_repo),
        )
        conn.execute(
            "DELETE FROM messenger_outcomes "
            "WHERE delivered_at IS NOT NULL AND delivered_at < ?",
            (time.time() - 86400,),
        )

    @staticmethod
    def _public_row(row: sqlite3.Row | dict[str, Any]) -> dict[str, Any]:
        data = dict(row)
        try:
            data["payload"] = json.loads(str(data.pop("payload_json")))
        except (json.JSONDecodeError, TypeError, ValueError):
            data["payload"] = {}
        return data


# ---------------------------------------------------------------------------
# Git worktree helpers
# ---------------------------------------------------------------------------

def _git(repo_path: str, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", repo_path, *args],
        capture_output=True, text=True, check=check,
    )


def _ticket_authoring_pathspecs(repo: Path, paths: list[Path]) -> list[str]:
    root = repo.resolve()
    return list(dict.fromkeys(str(path.resolve().relative_to(root)) for path in paths))


def _ensure_ticket_authoring_paths_clean(repo: Path, paths: list[Path]) -> None:
    pathspecs = _ticket_authoring_pathspecs(repo, paths)
    status = _git(
        str(repo), "status", "--porcelain", "--untracked-files=all", "--", *pathspecs,
        check=False,
    )
    if status.returncode != 0:
        raise ValueError(f"could not check ticket-authoring state: {status.stderr.strip()}")
    if status.stdout.strip():
        raise ValueError(
            "ticket authoring blocked by existing changes to "
            + ", ".join(pathspecs)
        )


def _commit_ticket_authorship(repo: Path, paths: list[Path], ticket_ids: list[str]) -> None:
    pathspecs = _ticket_authoring_pathspecs(repo, paths)
    status = _git(str(repo), "status", "--porcelain", "--untracked-files=all", check=False)
    if status.returncode != 0:
        raise ValueError(f"could not check repository status before ticket commit: {status.stderr.strip()}")

    staged = _git(str(repo), "diff", "--cached", "--name-only", check=False)
    if staged.returncode != 0:
        raise ValueError(f"could not inspect staged changes before ticket commit: {staged.stderr.strip()}")
    if staged.stdout.strip():
        raise ValueError("ticket authoring blocked by already-staged changes")

    add = _git(str(repo), "add", "--", *pathspecs, check=False)
    if add.returncode != 0:
        raise ValueError(f"could not stage ticket authorship: {(add.stderr or add.stdout).strip()}")

    commit = _git(
        str(repo),
        "commit",
        "-m",
        f"chore: author {', '.join(ticket_ids)} ticket{'s' if len(ticket_ids) != 1 else ''}",
        check=False,
    )
    if commit.returncode != 0:
        _git(str(repo), "restore", "--staged", "--worktree", "--", *pathspecs, check=False)
        raise ValueError(f"ticket authoring commit failed: {(commit.stderr or commit.stdout).strip()}")


def create_worktree(*, repo_path: str, workspace_path: Path, branch: str, base_branch: str) -> None:
    """Add a worktree for `branch` at `workspace_path`. Reuses if already a worktree on `branch`."""
    workspace_path.parent.mkdir(parents=True, exist_ok=True)

    list_out = _git(repo_path, "worktree", "list", "--porcelain", check=False).stdout
    if str(workspace_path) in list_out:
        return  # already exists as a worktree — reuse

    if workspace_path.exists():
        raise RuntimeError(f"{workspace_path} exists but is not a git worktree")

    add = _git(repo_path, "worktree", "add", "-b", branch, str(workspace_path), base_branch, check=False)
    if add.returncode == 0:
        return
    err = add.stderr or ""
    # Stale branch ref (no worktree owns it): delete and retry fresh off base. This recovers
    # from a prior cancel that left the ref behind, or a default_branch change on the project.
    if "already exists" in err:
        delete_branch(repo_path, branch)
        retry = _git(repo_path, "worktree", "add", "-b", branch, str(workspace_path), base_branch, check=False)
        if retry.returncode == 0:
            return
        raise RuntimeError(f"git worktree add (after stale branch cleanup) failed: {retry.stderr.strip()}")
    if "already used" in err:
        raise RuntimeError(
            f"branch {branch} is checked out by another worktree; cancel that run first: {err.strip()}"
        )
    raise RuntimeError(f"git worktree add failed: {err.strip()}")


def remove_worktree(repo_path: str, workspace_path: Path) -> tuple[bool, str | None]:
    """Remove a worktree. Returns (removed, error).

    `git worktree remove --force` can silently leave the directory in place if
    the worker process still holds open file descriptors / cwd inside it at the
    moment of pruning (e.g., right after SIGTERM). When that happens, fall back
    to `rm -rf` + `git worktree prune` so git's bookkeeping stays consistent.
    """
    result = _git(repo_path, "worktree", "remove", "--force", str(workspace_path), check=False)
    if not workspace_path.exists():
        return True, None

    try:
        shutil.rmtree(workspace_path)
    except OSError as e:
        git_err = (result.stderr or "").strip() or f"exit={result.returncode}"
        return False, f"git worktree remove failed ({git_err}); rmtree fallback failed: {e}"

    _git(repo_path, "worktree", "prune", check=False)
    if workspace_path.exists():
        return False, f"worktree directory still present after rm -rf: {workspace_path}"
    return True, None


def delete_branch(repo_path: str, branch: str) -> None:
    """Force-delete a local branch ref. Best-effort — git will refuse if a worktree still owns it."""
    _git(repo_path, "branch", "-D", branch, check=False)


SPIKE_RESULT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "conclusions": {"type": "array", "items": {"type": "string"}, "minItems": 1},
        "evidence": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "source": {"type": "string"},
                    "finding": {"type": "string"},
                },
                "required": ["source", "finding"],
            },
            "minItems": 1,
        },
        "uncertainties": {"type": "array", "items": {"type": "string"}},
        "recommended_next_steps": {"type": "array", "items": {"type": "string"}},
        "mutation_attempts": {"type": "array", "items": {"type": "string"}},
    },
    "required": [
        "conclusions",
        "evidence",
        "uncertainties",
        "recommended_next_steps",
        "mutation_attempts",
    ],
}


def _make_tree_writable(path: Path) -> None:
    if not path.exists():
        return
    for root, dirs, files in os.walk(path):
        root_path = Path(root)
        try:
            root_path.chmod(root_path.stat().st_mode | 0o700)
        except OSError:
            pass
        for name in [*dirs, *files]:
            child = root_path / name
            if child.is_symlink():
                continue
            try:
                child.chmod(child.stat().st_mode | 0o700)
            except OSError:
                pass


def create_spike_workspace(
    *, repo_path: str, workspace_path: Path, base_branch: str
) -> None:
    """Create an isolated detached clone and make it read-only for a spike."""
    if workspace_path.exists():
        raise RuntimeError(f"spike workspace already exists: {workspace_path}")
    workspace_path.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["GIT_LFS_SKIP_SMUDGE"] = "1"
    clone = subprocess.run(
        [
            "git", "-c", "core.hooksPath=/dev/null", "clone", "--no-local",
            "--no-checkout", "--quiet", repo_path, str(workspace_path),
        ],
        capture_output=True,
        text=True,
        env=env,
    )
    if clone.returncode != 0:
        shutil.rmtree(workspace_path, ignore_errors=True)
        raise RuntimeError(f"spike snapshot clone failed: {(clone.stderr or clone.stdout).strip()}")
    revision = f"refs/remotes/origin/{base_branch}"
    if _git(str(workspace_path), "rev-parse", "--verify", revision, check=False).returncode != 0:
        revision = "HEAD"
    checkout = subprocess.run(
        [
            "git", "-c", "core.hooksPath=/dev/null", "-C", str(workspace_path),
            "checkout", "--detach", "--quiet", revision,
        ],
        capture_output=True,
        text=True,
        env=env,
    )
    if checkout.returncode != 0:
        shutil.rmtree(workspace_path, ignore_errors=True)
        raise RuntimeError(f"spike snapshot checkout failed: {(checkout.stderr or checkout.stdout).strip()}")
    _git(str(workspace_path), "remote", "remove", "origin", check=False)
    for child in sorted(workspace_path.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        if child.is_symlink():
            continue
        try:
            child.chmod(child.stat().st_mode & ~0o222)
        except OSError as e:
            _make_tree_writable(workspace_path)
            shutil.rmtree(workspace_path, ignore_errors=True)
            raise RuntimeError(f"could not protect spike snapshot: {e}") from e
    workspace_path.chmod(workspace_path.stat().st_mode & ~0o222)


def remove_spike_workspace(workspace_path: Path) -> tuple[bool, str | None]:
    if not workspace_path.exists():
        return True, None
    _make_tree_writable(workspace_path)
    try:
        shutil.rmtree(workspace_path)
    except OSError as e:
        return False, f"could not remove spike workspace: {e}"
    return not workspace_path.exists(), None


def _spike_text(value: Any, *, field: str, max_length: int = 600) -> str:
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    if not text:
        raise ValueError(f"spike result {field} contains an empty value")
    return text[:max_length]


def validate_spike_result(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("spike result is not an object")
    expected = set(SPIKE_RESULT_SCHEMA["required"])
    if set(value) != expected:
        raise ValueError("spike result fields do not match the structured contract")

    def strings(field: str, *, required: bool = False) -> list[str]:
        raw = value.get(field)
        if not isinstance(raw, list) or (required and not raw):
            raise ValueError(f"spike result {field} must be a non-empty list" if required else f"spike result {field} must be a list")
        if len(raw) > 12:
            raise ValueError(f"spike result {field} exceeds 12 items")
        return [_spike_text(item, field=field) for item in raw]

    evidence_raw = value.get("evidence")
    if not isinstance(evidence_raw, list) or not evidence_raw or len(evidence_raw) > 12:
        raise ValueError("spike result evidence must contain 1-12 items")
    evidence: list[dict[str, str]] = []
    for item in evidence_raw:
        if not isinstance(item, dict) or set(item) != {"source", "finding"}:
            raise ValueError("spike result evidence entries require source and finding")
        evidence.append({
            "source": _spike_text(item["source"], field="evidence.source", max_length=300),
            "finding": _spike_text(item["finding"], field="evidence.finding"),
        })
    result = {
        "conclusions": strings("conclusions", required=True),
        "evidence": evidence,
        "uncertainties": strings("uncertainties"),
        "recommended_next_steps": strings("recommended_next_steps"),
        "mutation_attempts": strings("mutation_attempts"),
    }
    if result["mutation_attempts"]:
        raise ValueError(
            "spike reported blocked mutation attempt(s): "
            + "; ".join(result["mutation_attempts"])
        )
    return result


def extract_spike_result(log_path: Path) -> dict[str, Any]:
    candidates: list[Any] = []
    last_error: ValueError | None = None
    try:
        lines = log_path.read_text(errors="replace").splitlines()
    except OSError as e:
        raise ValueError(f"could not read spike output: {e}") from e
    for line in lines:
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(event, dict):
            continue
        if isinstance(event.get("structured_output"), dict):
            candidates.append(event["structured_output"])
        item = event.get("item")
        if isinstance(item, dict) and item.get("type") == "agent_message":
            candidates.append(item.get("text"))
        if event.get("type") == "result":
            candidates.append(event.get("result"))
    for candidate in reversed(candidates):
        if isinstance(candidate, str):
            try:
                candidate = json.loads(candidate)
            except json.JSONDecodeError:
                continue
        try:
            return validate_spike_result(candidate)
        except ValueError as e:
            last_error = e
            continue
    if last_error is not None:
        raise last_error
    raise ValueError("provider returned no valid structured spike result")


def _replace_markdown_section(body: str, heading: str, content: str) -> str:
    pattern = re.compile(
        rf"^## {re.escape(heading)}\s*\n.*?(?=^## |\Z)",
        re.MULTILINE | re.DOTALL | re.IGNORECASE,
    )
    section = f"## {heading}\n\n{content.strip()}\n"
    if pattern.search(body):
        return pattern.sub(section, body, count=1)
    return body.rstrip() + "\n\n" + section


def render_spike_report(
    result: dict[str, Any], *, run_id: int, attempt: int, provider: str
) -> str:
    def bullets(items: list[str], empty: str) -> str:
        return "\n".join(f"- {item}" for item in items) if items else f"- {empty}"

    evidence = "\n".join(
        f"- `{item['source']}` - {item['finding']}" for item in result["evidence"]
    )
    return (
        f"- **Run:** {run_id} (attempt {attempt})\n"
        f"- **Provider:** {provider}\n\n"
        "**Conclusions**\n\n"
        f"{bullets(result['conclusions'], 'No conclusion recorded.')}\n\n"
        "**Evidence**\n\n"
        f"{evidence}\n\n"
        "**Uncertainties**\n\n"
        f"{bullets(result['uncertainties'], 'None recorded.')}\n\n"
        "**Recommended next steps**\n\n"
        f"{bullets(result['recommended_next_steps'], 'No follow-up recommended.')}"
    )


def commit_daemon_ticket_update(
    *, repo: Path, ticket_path: Path, ticket: dict[str, Any], message: str
) -> None:
    original = ticket_path.read_text()
    write_ticket(ticket_path, ticket)
    rel = str(ticket_path.resolve().relative_to(repo.resolve()))
    commit = _git(
        str(repo), "commit", "--only", "-m", message, "--", rel, check=False,
    )
    if commit.returncode == 0:
        return
    ticket_path.write_text(original)
    raise RuntimeError(
        f"daemon ticket-only commit failed: {(commit.stderr or commit.stdout).strip()}"
    )


def _git_head(repo_path: str) -> str | None:
    result = _git(repo_path, "rev-parse", "HEAD", check=False)
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def _git_text(repo_path: str, *args: str) -> str:
    result = _git(repo_path, *args, check=False)
    text = (result.stdout or "").strip()
    if result.returncode != 0:
        err = (result.stderr or "").strip()
        return err or text or f"git {' '.join(args)} failed with exit {result.returncode}"
    return text


def _tail_text(path: Path, *, max_lines: int = 160, max_chars: int = 20_000) -> str:
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError as e:
        return f"unavailable: {e}"
    return "\n".join(lines[-max_lines:])[-max_chars:]


def _ticket_run_log(ticket_body: str) -> str:
    marker = "## Run log"
    index = ticket_body.find(marker)
    if index < 0:
        return ""
    return ticket_body[index:].strip()


def validate_worker_outcome(
    *,
    workspace_path: str,
    ticket_id: str,
    run_id: int,
    start_head: str | None,
) -> tuple[str | None, str]:
    """Return the declared, committed outcome for an exit-0 worker.

    Agent CLIs can return 0 after answering a clarification or unrelated prompt.
    The orchestrator treats ticket completion as on-disk evidence in the worker
    worktree: a new commit, the requested ticket marked done or verification
    blocked, and a run-log body that mentions the current run. Verification
    blockers must name the exact external condition and explicit resume path.
    """
    workspace = Path(workspace_path)
    ticket_path = workspace / ".orchestrator" / f"{ticket_id}.md"
    reasons: list[str] = []

    current_head = _git_head(str(workspace))
    if start_head and current_head == start_head:
        reasons.append("worker made no new commit")
    elif current_head is None:
        reasons.append("could not read worker git HEAD")

    try:
        ticket = read_ticket(ticket_path)
    except FileNotFoundError:
        return None, f"ticket file missing at {ticket_path}"
    except (OSError, TicketParseError) as e:
        return None, f"ticket file unreadable at {ticket_path}: {e}"

    if ticket.get("id") != ticket_id:
        reasons.append(f"ticket id is {ticket.get('id')!r}, expected {ticket_id!r}")
    status = str(ticket.get("status") or "")
    if status not in {"done", VERIFICATION_BLOCKED_STATUS}:
        reasons.append(
            f"ticket status is {status!r}, expected 'done' or {VERIFICATION_BLOCKED_STATUS!r}"
        )
    if status == VERIFICATION_BLOCKED_STATUS:
        for field in VERIFICATION_BLOCKER_FIELDS:
            if not str(ticket.get(field) or "").strip():
                reasons.append(f"verification-blocked ticket is missing {field}")
    if ticket.get("run_id") != run_id:
        reasons.append(f"ticket run_id is {ticket.get('run_id')!r}, expected {run_id}")

    rel_ticket = f".orchestrator/{ticket_id}.md"
    diff = _git(str(workspace), "diff", "--quiet", "HEAD", "--", rel_ticket, check=False)
    if diff.returncode == 1:
        reasons.append("ticket completion is not committed")
    elif diff.returncode != 0:
        reasons.append("could not verify committed ticket completion")

    body = str(ticket.get("body") or "")
    if "## Run log" not in body or str(run_id) not in body:
        reasons.append(f"ticket run log does not mention run {run_id}")

    if reasons:
        return None, "; ".join(reasons)
    if status == VERIFICATION_BLOCKED_STATUS:
        blocker = str(ticket["verification_blocker"]).strip()
        resume = str(ticket["verification_resume"]).strip()
        return status, f"verification blocked: {blocker}; resume: {resume}"
    return status, "ticket marked done with run evidence"


def validate_worker_completion(
    *,
    workspace_path: str,
    ticket_id: str,
    run_id: int,
    start_head: str | None,
) -> tuple[bool, str]:
    """Compatibility wrapper for callers that require a fully done ticket."""
    outcome, reason = validate_worker_outcome(
        workspace_path=workspace_path,
        ticket_id=ticket_id,
        run_id=run_id,
        start_head=start_head,
    )
    return outcome == "done", reason


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

def _agent_command(*, agent_kind: str, agent_bin: str, run: dict) -> list[str]:
    model_alias = str(run.get("model_alias") or "").strip().lower()
    worker_effort = str(run.get("worker_effort") or "").strip().lower()
    spike = run.get("execution_mode") == SPIKE_EXECUTION_MODE
    if agent_kind == "claude":
        if model_alias == "default":
            model_alias = ""
        if worker_effort == "default":
            worker_effort = ""
        # Claude stream-json gives assistant/tool_use/tool_result events. The
        # same command shape is used for implementation and review workers so
        # provider-facing effort semantics stay aligned.
        if spike:
            cmd = [
                agent_bin,
                "-p",
                "--safe-mode",
                "--no-chrome",
                "--no-session-persistence",
                "--permission-mode", "dontAsk",
                "--tools", "Read,Glob,Grep",
                "--strict-mcp-config",
                "--mcp-config", "{}",
                "--json-schema", json.dumps(SPIKE_RESULT_SCHEMA, separators=(",", ":")),
                "--verbose",
                "--output-format", "stream-json",
            ]
        else:
            cmd = [
                agent_bin,
                "-p",
                "--dangerously-skip-permissions",
                "--verbose",
                "--output-format", "stream-json",
            ]
        if model_alias:
            cmd.extend(["--model", model_alias])
        if worker_effort:
            cmd.extend(["--effort", worker_effort])
        return cmd

    if model_alias:
        family = normalize_codex_family(model_alias)
        try:
            resolved = resolve_codex_family_from_cli(family, command=agent_bin)
            model_alias = resolved.launch_model
            run["selected_model_family"] = family
            run["resolved_model_alias"] = model_alias
            if worker_effort:
                worker_effort = resolve_codex_effort(worker_effort, resolved)
                run["resolved_worker_effort"] = worker_effort
        except CodexModelResolutionError as exc:
            raise RuntimeError(f"could not resolve Codex worker model {model_alias!r}: {exc}") from exc
    if worker_effort == "default":
        worker_effort = ""

    # Codex exec --json emits JSONL events such as thread.started,
    # item.started command_execution, item.completed, and turn.completed.
    if spike:
        schema_path = str(run.get("result_schema_path") or "").strip()
        if not schema_path:
            raise RuntimeError("spike run is missing its structured result schema")
        cmd = [
            agent_bin,
            "exec",
            "--json",
            "--ephemeral",
            "--sandbox", "read-only",
            "--ignore-user-config",
            "--ignore-rules",
            "--output-schema", schema_path,
        ]
    else:
        cmd = [
            agent_bin,
            "exec",
            "--json",
            "--ephemeral",
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-bypass-hook-trust",
        ]
    if model_alias:
        cmd.extend(["--model", model_alias])
    if worker_effort:
        cmd.extend(["--config", f"model_reasoning_effort={worker_effort}"])
    return cmd


class Worker:
    """One agent subprocess running against a worktree. Owns its own thread."""

    def __init__(self, *, run_id: int, run: dict, prompt: str, agent_bin: str,
                 agent_kind: str,
                 workflow_path: Path | None = None,
                 store: RunsStore, log_path: Path,
                 on_complete: Callable[[int], None] | None = None,
                 emit_lifecycle: Callable[..., dict[str, Any] | None] | None = None,
                 artifact_completion_validator: Callable[[str | None], tuple[str | None, str]] | None = None):
        self.run_id = run_id
        self.run = run
        self.prompt = prompt
        self.agent_bin = agent_bin
        self.agent_kind = agent_kind
        self.workflow_path = workflow_path
        self.store = store
        self.log_path = log_path
        self.on_complete = on_complete
        self.emit_lifecycle = emit_lifecycle
        self.artifact_completion_validator = artifact_completion_validator
        self.proc: subprocess.Popen | None = None
        self.thread: threading.Thread | None = None
        self._cancel_requested = threading.Event()
        self.spike_result: dict[str, Any] | None = None
        self._spike_violation: str | None = None
        # Tool-use ids dispatched but not yet resolved by a tool_result. Shared
        # with the heartbeat thread, so guarded by a lock.
        self._inflight: set[str] = set()
        self._inflight_lock = threading.Lock()

    def start(self) -> None:
        self.thread = threading.Thread(target=self._run, name=f"worker-{self.run_id}", daemon=True)
        self.thread.start()

    def _emit_lifecycle(
        self,
        kind: str,
        *,
        message: str | None = None,
        queue_messenger: bool = True,
    ) -> None:
        kwargs = {
            "ticket_id": self.run["ticket_id"],
            "run_id": self.run_id,
            "source": "worker",
            "message": message,
            "repo_path": self.run.get("repo_path"),
            "provider_key": self.run.get("provider_key") or self.agent_kind,
            "queue_messenger": queue_messenger,
        }
        if self.emit_lifecycle is not None:
            self.emit_lifecycle(kind, **kwargs)
            return
        _notify_orchestration_trace(
            kind,
            ticket_id=kwargs["ticket_id"],
            run_id=self.run_id,
            source="worker",
            message=message,
        )

    def _run(self) -> None:
        try:
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            log = self.log_path.open("w")
        except OSError as e:
            self.store.update(self.run_id, state="Failed", last_error=f"Could not open log: {e}", ended=True)
            self._emit_lifecycle("run-failed")
            self._notify_complete()
            return

        try:
            log.write(f"[orchestrator] provider={self.agent_kind}\n")
            log.write(
                f"[orchestrator] execution_mode={self.run.get('execution_mode') or 'implementation'}\n"
            )
            if self.run.get("model_alias"):
                log.write(f"[orchestrator] model_alias={self.run['model_alias']}\n")
            if self.run.get("worker_model"):
                log.write(f"[orchestrator] worker_model={self.run['worker_model']}\n")
            if self.run.get("worker_effort"):
                log.write(f"[orchestrator] worker_effort={self.run['worker_effort']}\n")
            if self.run.get("worker_sizing_rationale"):
                log.write(f"[orchestrator] worker_sizing_rationale={self.run['worker_sizing_rationale']}\n")
            if self.run.get("worker_provider_notes"):
                log.write(f"[orchestrator] worker_provider_notes={self.run['worker_provider_notes']}\n")
            if self.workflow_path:
                log.write(f"[orchestrator] workflow_template={self.workflow_path}\n")
            log.write(f"[orchestrator] prompt_sha256={hashlib.sha256(self.prompt.encode('utf-8')).hexdigest()}\n")
            start_head = _git_head(self.run["workspace_path"])
            if start_head:
                log.write(f"[orchestrator] start_head={start_head}\n")
            try:
                cmd = self._command()
            except RuntimeError as e:
                self.store.update(
                    self.run_id,
                    state="Failed",
                    last_error=str(e),
                    ended=True,
                    exit_code=-1,
                )
                log.write(f"[orchestrator] {e}\n")
                self._emit_lifecycle("run-failed")
                return
            if self.run.get("selected_model_family"):
                log.write(f"[orchestrator] selected_model_family={self.run['selected_model_family']}\n")
            if self.run.get("resolved_model_alias"):
                log.write(f"[orchestrator] resolved_model_alias={self.run['resolved_model_alias']}\n")
            if self.run.get("resolved_worker_effort"):
                log.write(f"[orchestrator] resolved_worker_effort={self.run['resolved_worker_effort']}\n")
            try:
                self.proc = subprocess.Popen(
                    cmd,
                    cwd=self.run["workspace_path"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )
            except FileNotFoundError as e:
                self.store.update(self.run_id, state="Failed",
                                  last_error=f"{self.agent_kind} CLI not found: {e}",
                                  ended=True, exit_code=-1)
                log.write(f"[orchestrator] {self.agent_kind} CLI not found: {e}\n")
                self._emit_lifecycle("run-failed")
                return

            self.store.update(self.run_id, state="Running", pid=self.proc.pid)
            self._emit_lifecycle("run-running", queue_messenger=False)

            # Feed the prompt and close stdin so the agent starts. The prompt is a
            # few KB — well under the pipe buffer — so this single write won't
            # deadlock against the stdout reads below.
            try:
                if self.proc.stdin:
                    self.proc.stdin.write(self.prompt)
                    self.proc.stdin.close()
            except (BrokenPipeError, OSError):
                pass

            # Keep activity_at fresh while a tool is in flight (e.g. a long
            # `swift build`) so the board doesn't read it as stalled.
            hb_stop = threading.Event()
            hb_thread = threading.Thread(
                target=self._heartbeat, args=(hb_stop,),
                name=f"worker-{self.run_id}-hb", daemon=True,
            )
            hb_thread.start()

            tail: collections.deque[str] = collections.deque(maxlen=5)
            last_meaningful_at = 0.0
            try:
                for line in self.proc.stdout:  # type: ignore[union-attr]
                    log.write(line)
                    # The daemon's advisory health check observes log growth.
                    log.flush()
                    stripped = line.strip()
                    if not stripped:
                        continue
                    tail.append(stripped[:500])
                    last_meaningful_at = self._handle_event(stripped, last_meaningful_at)
            finally:
                log.flush()
                hb_stop.set()

            self.proc.wait()
            rc = self.proc.returncode

            if self._cancel_requested.is_set():
                self.store.update(self.run_id, state="Canceled", ended=True, exit_code=rc)
                self._emit_lifecycle("run-canceled")
            elif rc == 0:
                if self.run.get("execution_mode") == SPIKE_EXECUTION_MODE:
                    try:
                        if self._spike_violation:
                            raise ValueError(self._spike_violation)
                        self.spike_result = extract_spike_result(self.log_path)
                    except ValueError as e:
                        reason = str(e)
                        log.write(f"\n[orchestrator] spike incomplete: {reason}\n")
                        self.store.update(
                            self.run_id,
                            state="Failed",
                            last_error=reason,
                            ended=True,
                            exit_code=rc,
                        )
                        self._emit_lifecycle("run-failed")
                    else:
                        self.store.update(
                            self.run_id,
                            state="SpikeResultReady",
                            ended=True,
                            exit_code=rc,
                        )
                        self._emit_lifecycle("preparing-response", queue_messenger=False)
                else:
                    if self.artifact_completion_validator is not None:
                        outcome, reason = self.artifact_completion_validator(start_head)
                    else:
                        outcome, reason = validate_worker_outcome(
                            workspace_path=self.run["workspace_path"],
                            ticket_id=self.run["ticket_id"],
                            run_id=self.run_id,
                            start_head=start_head,
                        )
                    if outcome in {"done", "completed", VERIFICATION_BLOCKED_STATUS}:
                        self.store.update(
                            self.run_id,
                            state="AwaitingReview",
                            last_error=(reason if outcome == VERIFICATION_BLOCKED_STATUS else None),
                            ended=True,
                            exit_code=rc,
                        )
                        self._emit_lifecycle(
                            "run-review-needed",
                            message=(
                                f"{self.run['ticket_id']} declared an external verification blocker and needs review"
                                if outcome == VERIFICATION_BLOCKED_STATUS
                                else None
                            ),
                        )
                    else:
                        log.write(f"\n[orchestrator] worker exited 0 but did not complete ticket: {reason}\n")
                        self.store.update(
                            self.run_id,
                            state="Failed",
                            last_error=f"exit=0 but ticket incomplete: {reason}",
                            ended=True,
                            exit_code=rc,
                        )
                        self._emit_lifecycle("run-failed")
            elif rc in (-9, -15):
                self.store.update(self.run_id, state="Canceled", ended=True, exit_code=rc)
                self._emit_lifecycle("run-canceled")
            else:
                self.store.update(self.run_id, state="Failed",
                                  last_error=f"exit={rc}; tail={' / '.join(tail)[:500]}",
                                  ended=True, exit_code=rc)
                self._emit_lifecycle("run-failed")
        finally:
            if self.proc and self.proc.stdout:
                try:
                    self.proc.stdout.close()
                except OSError:
                    pass
            try:
                log.close()
            except OSError:
                pass
            self._notify_complete()

    def _command(self) -> list[str]:
        return _agent_command(
            agent_kind=self.agent_kind,
            agent_bin=self.agent_bin,
            run=self.run,
        )

    def _notify_complete(self):
        if self.on_complete:
            try:
                self.on_complete(self.run_id)
            except Exception:  # noqa: BLE001 — don't let callback crash worker thread
                pass

    def _heartbeat(self, stop: threading.Event) -> None:
        while not stop.wait(ACTIVITY_HEARTBEAT_SECONDS):
            with self._inflight_lock:
                busy = bool(self._inflight)
            if busy:
                self.store.touch_activity(self.run_id)

    def _handle_event(self, line: str, last_meaningful_at: float) -> float:
        """Parse one stream-json line and update the live activity summary.
        Tolerant of unknown shapes — the format evolves, so anything we don't
        recognise is ignored. Returns the (possibly updated) timestamp of the
        last *meaningful* tool call, used to debounce no-op tools."""
        try:
            evt = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            return last_meaningful_at
        if not isinstance(evt, dict):
            return last_meaningful_at

        etype = evt.get("type")
        if etype == "assistant":
            content = ((evt.get("message") or {}).get("content")) or []
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                tool_id = block.get("id")
                if tool_id:
                    with self._inflight_lock:
                        self._inflight.add(tool_id)
                name = block.get("name") or ""
                if self.run.get("execution_mode") == SPIKE_EXECUTION_MODE and name not in {
                    "Read", "Glob", "Grep"
                }:
                    self._spike_violation = f"spike attempted disallowed tool {name or 'unknown'}"
                now = time.time()
                meaningful = name not in _NOOP_TOOLS
                # Don't let a no-op tool clobber a useful activity set seconds ago.
                if not meaningful and (now - last_meaningful_at) < ACTIVITY_DEBOUNCE_SECONDS:
                    continue
                self.store.set_activity(self.run_id, derive_activity(name, block.get("input")))
                if meaningful:
                    last_meaningful_at = now
        elif etype == "user":
            content = ((evt.get("message") or {}).get("content")) or []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    tool_id = block.get("tool_use_id")
                    if tool_id:
                        with self._inflight_lock:
                            self._inflight.discard(tool_id)
        elif etype == "item.started":
            item = evt.get("item") or {}
            if isinstance(item, dict):
                if self.run.get("execution_mode") == SPIKE_EXECUTION_MODE:
                    command = str(item.get("command") or "")
                    if item.get("type") == "command_execution" and re.search(
                        r"(?:^|[;&|]\s*)(?:rm|mv|cp|touch|mkdir|install|curl|wget|open|osascript|chmod|chown|ln|tee)\b|"
                        r"(?:^|\s)(?:>|>>|2>|2>>)\s*|"
                        r"\bgit\s+(?:add|apply|branch|checkout|clean|commit|merge|push|rebase|reset|restore|switch|tag|worktree)\b",
                        command,
                    ):
                        self._spike_violation = "spike attempted a mutating or external command"
                item_id = item.get("id")
                if item_id:
                    with self._inflight_lock:
                        self._inflight.add(item_id)
                self.store.set_activity(self.run_id, derive_codex_activity(item))
        elif etype == "item.completed":
            item = evt.get("item") or {}
            if isinstance(item, dict):
                if (
                    self.run.get("execution_mode") == SPIKE_EXECUTION_MODE
                    and item.get("type") == "command_execution"
                    and item.get("exit_code") not in (None, 0, "0")
                    and re.search(
                        r"operation not permitted|permission denied|read-only|sandbox",
                        str(item.get("aggregated_output") or item.get("output") or ""),
                        re.IGNORECASE,
                    )
                ):
                    self._spike_violation = "spike command was blocked by mutation isolation"
                item_id = item.get("id")
                if item_id:
                    with self._inflight_lock:
                        self._inflight.discard(item_id)
        return last_meaningful_at

    def cancel(self) -> None:
        self._cancel_requested.set()
        self._terminate()

    def _terminate(self) -> None:
        proc = self.proc
        if not proc:
            return
        try:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        except OSError:
            pass


class ReviewWorker:
    """Follow-up agent that reviews and merges a completed implementation run."""

    def __init__(self, *, run_id: int, run: dict, prompt: str, agent_bin: str,
                 agent_kind: str, store: RunsStore, log_path: Path,
                 on_complete: Callable[[int], None] | None = None,
                 emit_lifecycle: Callable[..., dict[str, Any] | None] | None = None):
        self.run_id = run_id
        self.run = run
        self.prompt = prompt
        self.agent_bin = agent_bin
        self.agent_kind = agent_kind
        self.store = store
        self.log_path = log_path
        self.on_complete = on_complete
        self.emit_lifecycle = emit_lifecycle
        self.proc: subprocess.Popen | None = None
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        self.thread = threading.Thread(
            target=self._run,
            name=f"review-worker-{self.run_id}",
            daemon=True,
        )
        self.thread.start()

    def _emit_lifecycle(
        self,
        kind: str,
        *,
        message: str | None = None,
        queue_messenger: bool = True,
    ) -> None:
        kwargs = {
            "ticket_id": self.run["ticket_id"],
            "run_id": self.run_id,
            "source": "review-worker",
            "message": message,
            "repo_path": self.run.get("repo_path"),
            "provider_key": self.run.get("provider_key") or self.agent_kind,
            "queue_messenger": queue_messenger,
        }
        if self.emit_lifecycle is not None:
            self.emit_lifecycle(kind, **kwargs)
            return
        _notify_orchestration_trace(
            kind,
            ticket_id=kwargs["ticket_id"],
            run_id=self.run_id,
            source="review-worker",
            message=message,
        )

    def _run(self) -> None:
        try:
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            log = self.log_path.open("a")
        except OSError as e:
            self.store.update(
                self.run_id,
                state="AwaitingReview",
                last_error=f"Could not open review log: {e}",
            )
            self._emit_lifecycle(
                "run-review-needed",
                message=f"{self.run['ticket_id']} run {self.run_id} still needs review attention",
            )
            self._notify_complete()
            return

        try:
            log.write(f"\n[orchestrator] review_provider={self.agent_kind}\n")
            log.write(f"[orchestrator] review_prompt_sha256={hashlib.sha256(self.prompt.encode('utf-8')).hexdigest()}\n")
            cmd = self._command()
            try:
                self.proc = subprocess.Popen(
                    cmd,
                    cwd=self.run["repo_path"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )
            except FileNotFoundError as e:
                self.store.update(
                    self.run_id,
                    state="AwaitingReview",
                    last_error=f"{self.agent_kind} review CLI not found: {e}",
                )
                log.write(f"[orchestrator] {self.agent_kind} review CLI not found: {e}\n")
                self._emit_lifecycle(
                    "run-review-needed",
                    message=f"{self.run['ticket_id']} run {self.run_id} still needs review attention",
                )
                return

            self.store.update(self.run_id, state="Reviewing", pid=self.proc.pid)
            self.store.set_activity(self.run_id, "Reviewing worker branch")
            self._emit_lifecycle("run-reviewing", queue_messenger=False)

            try:
                if self.proc.stdin:
                    self.proc.stdin.write(self.prompt)
                    self.proc.stdin.close()
            except (BrokenPipeError, OSError):
                pass

            hb_stop = threading.Event()
            hb_thread = threading.Thread(
                target=self._heartbeat,
                args=(hb_stop,),
                name=f"review-worker-{self.run_id}-hb",
                daemon=True,
            )
            hb_thread.start()
            tail: collections.deque[str] = collections.deque(maxlen=5)
            try:
                for line in self.proc.stdout:  # type: ignore[union-attr]
                    log.write(line)
                    # The daemon's advisory health check observes log growth.
                    log.flush()
                    stripped = line.strip()
                    if stripped:
                        tail.append(stripped[:500])
            finally:
                log.flush()
                hb_stop.set()

            self.proc.wait()
            rc = self.proc.returncode
            current = self.store.get(self.run_id) or {}
            if current.get("state") in {
                "Merged",
                "MergeConflict",
                VERIFICATION_BLOCKED_RUN_STATE,
                "Failed",
            }:
                return

            if rc == 0:
                reason = "review worker exited 0 without accepting or retrying run"
            else:
                reason = f"review worker failed: exit={rc}; tail={' / '.join(tail)[:500]}"
            self.store.update(self.run_id, state="AwaitingReview", last_error=reason)
            self._emit_lifecycle(
                "run-review-needed",
                message=f"{self.run['ticket_id']} run {self.run_id} still needs review attention",
            )
        finally:
            if self.proc and self.proc.stdout:
                try:
                    self.proc.stdout.close()
                except OSError:
                    pass
            try:
                log.close()
            except OSError:
                pass
            self._notify_complete()

    def _command(self) -> list[str]:
        return _agent_command(
            agent_kind=self.agent_kind,
            agent_bin=self.agent_bin,
            run=self.run,
        )

    def _heartbeat(self, stop: threading.Event) -> None:
        while not stop.wait(ACTIVITY_HEARTBEAT_SECONDS):
            self.store.touch_activity(self.run_id)

    def _notify_complete(self):
        if self.on_complete:
            try:
                self.on_complete(self.run_id)
            except Exception:  # noqa: BLE001 — don't let callback crash worker thread
                pass


# ---------------------------------------------------------------------------
# Daemon (orchestration logic + HTTP server)
# ---------------------------------------------------------------------------

class Daemon:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        orch_cfg = cfg.get("orchestrator", {})
        self.workspace_root = _resolve_workspace_root(orch_cfg.get("workspace_root", ""))
        self.workspace_root.mkdir(parents=True, exist_ok=True)
        self.branch_prefix = orch_cfg.get("branch_prefix", "relay/")
        self.workflow_path = _resolve_workflow_default(orch_cfg.get("default_workflow_path", ""))
        self.worker_health_check_seconds = max(
            1.0,
            float(
                orch_cfg.get(
                    "worker_health_check_seconds",
                    DEFAULT_WORKER_HEALTH_CHECK_SECONDS,
                )
            ),
        )
        self.port = int(orch_cfg.get("port", DEFAULT_PORT))
        self.max_concurrent_workers = max(0, int(orch_cfg.get("max_concurrent_workers", 0) or 0))

        data = _data_root()
        self.runs = RunsStore(data / "runs.db", index_path=data / "runs.json")
        self.queue_drains = QueueDrainStore(data / "queue_drains.db")
        self.orchestrator_sessions = OrchestratorSessionStore(data / "orchestrator_sessions.db")
        self.orchestrator_commands = OrchestratorCommandStore(data / "orchestrator_commands.db")
        self.messenger_outcomes = MessengerOutcomeStore(data / "messenger_outcomes.db")
        self.followup_proposals = FollowupProposalStore(data / "followup_proposals.db")
        self.graphify_path = data / "graphify.db"
        self.program_registry_path = _program_registry_path()
        self.project_registry_v2_path = data / "projects" / "registry-v2.json"
        self._artifact_state_root = data
        self._artifact_device_id = "daemon-" + hashlib.sha256(
            f"{socket.gethostname()}:{data}".encode("utf-8")
        ).hexdigest()[:24]
        self._artifact_lifecycles: dict[str, ArtifactLifecycleCoordinator] = {}
        self._artifact_lifecycles_lock = threading.Lock()

        # MVP: single concurrency. Held during the dispatch claim → spawn window
        # (release immediately after spawn — the worker runs in its own thread).
        self._dispatch_lock = threading.Lock()
        self._ticket_authoring_lock = threading.Lock()
        self._orchestrator_action_request_ids: set[str] = set()
        self._workers: dict[int, Worker] = {}
        self._workers_lock = threading.Lock()
        self._review_workers: dict[int, ReviewWorker] = {}
        self._review_workers_lock = threading.Lock()
        self._run_health: dict[int, dict[str, Any]] = {}
        self._run_health_lock = threading.Lock()

        stalled = self.runs.reconcile_on_startup()
        if stalled:
            print(f"[orchestrator] reconciled {stalled} stalled run(s) on startup", file=sys.stderr)
            self._recover_stalled_spikes()
        # Seed the runs-index file so the board has something to read before the
        # first transition (reconcile above mutates state directly, bypassing the
        # insert/update write hooks).
        self.runs.write_index()
        self._recover_artifact_lifecycle_leases()
        stale_sessions = self.orchestrator_sessions.reconcile_stale()
        if stale_sessions:
            print(
                f"[orchestrator] reconciled {stale_sessions} stale orchestrator session(s) on startup",
                file=sys.stderr,
            )

        agent_setting = orch_cfg.get("agent") or cfg.get("general", {}).get("command") or "codex"
        self.config_loader = load_config
        self.agent_kind = _agent_kind(str(agent_setting))
        self.agent_bin = _find_agent_bin(
            self.agent_kind,
            str(orch_cfg.get("command") or ""),
        )
        try:
            self.reconcile_queue_drains(trigger="daemon-startup")
        except Exception as e:  # noqa: BLE001 - daemon startup must still finish.
            print(f"[orchestrator] queue-drain startup reconcile failed: {e}", file=sys.stderr)

    def _artifact_lifecycle(self, repo_path: str) -> ArtifactLifecycleCoordinator | None:
        repo = Path(repo_path).expanduser().resolve()
        config_path = repo / ".orchestrator" / "config.toml"
        try:
            config = tomllib.loads(config_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError):
            return None
        if config.get("artifact_lifecycle", "legacy") != "enabled":
            return None
        project_id = str(config.get("project_id") or "").strip()
        if not project_id:
            raise ValueError("artifact lifecycle config has no immutable project_id")
        key = str(repo)
        with self._artifact_lifecycles_lock:
            coordinator = self._artifact_lifecycles.get(key)
            if coordinator is None or coordinator.store.project_id != project_id:
                store = ArtifactStore(
                    repo,
                    project_id,
                    self._artifact_state_root,
                    enabled=True,
                )
                if not ArtifactLifecycleCoordinator.is_enabled(store):
                    return None
                coordinator = ArtifactLifecycleCoordinator(
                    store,
                    registry_path=self.project_registry_v2_path,
                    device_id=self._artifact_device_id,
                )
                self._artifact_lifecycles[key] = coordinator
            return coordinator

    def _recover_artifact_lifecycle_leases(self) -> None:
        try:
            document = json.loads(self.project_registry_v2_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        for record in document.get("projects", []):
            if not isinstance(record, dict) or record.get("availability") != "available":
                continue
            repo_path = str(record.get("last_resolved_path") or "").strip()
            if not repo_path:
                continue
            try:
                lifecycle = self._artifact_lifecycle(repo_path)
                if lifecycle is not None:
                    def run_state(run_id: int) -> str | None:
                        run = self.runs.get(run_id)
                        return str(run.get("state")) if run and run.get("state") else None

                    lifecycle.recover_leases(
                        run_state
                    )
            except Exception as error:  # noqa: BLE001 - startup remains available.
                print(
                    f"[orchestrator] artifact lifecycle recovery failed for {repo_path}: {error}",
                    file=sys.stderr,
                )

    # -- prompt rendering -------------------------------------------------

    def _emit_lifecycle(
        self,
        kind: str,
        *,
        ticket_id: str | None = None,
        run_id: int | None = None,
        source: str = "orchestrator",
        message: str | None = None,
        repo_path: str | None = None,
        provider_key: str | None = None,
        queue_messenger: bool = True,
    ) -> dict[str, Any] | None:
        payload = _orchestration_trace_payload(
            kind,
            ticket_id=ticket_id,
            run_id=run_id,
            source=source,
            message=message,
        )
        if payload is None:
            return None
        _notify_state("working", **payload)
        if queue_messenger and repo_path:
            self.messenger_outcomes.record(
                repo_path=repo_path,
                provider_key=provider_key,
                payload=payload,
            )
        return payload

    def _resolve_workflow_for_repo(self, repo_path: str) -> Path:
        repo_template = Path(repo_path) / ".orchestrator" / "WORKFLOW.md"
        if repo_template.is_file():
            return repo_template
        return self.workflow_path

    @staticmethod
    def _validate_workflow_template(template_path: Path, template: str) -> None:
        missing = [
            marker
            for marker in ("{{ticket_id}}", "{{run_id}}")
            if marker not in template
        ]
        if missing:
            raise RuntimeError(
                f"workflow template at {template_path} is not an orchestrator ticket workflow; "
                f"missing template variable(s): {', '.join(missing)}"
            )

    def _build_prompt(
        self, *, ticket_id: str, repo_path: str, workspace_path: str, branch: str, attempt: int, run_id: int,
        caller_context: str | None = None, workflow_path: Path | None = None,
    ) -> str:
        template_path = workflow_path or self._resolve_workflow_for_repo(repo_path)
        try:
            template = template_path.read_text()
        except OSError as e:
            raise RuntimeError(f"could not read workflow template at {template_path}: {e}") from e
        self._validate_workflow_template(template_path, template)
        # Sub-agents have no memory of the dispatching session. The caller can
        # pass `caller_context` to inject background that doesn't fit in the
        # ticket file (recent decisions, related runs, etc.). Wrap it in a
        # heading only when present so an empty value collapses cleanly.
        if caller_context and caller_context.strip():
            context_block = (
                "## Additional context from the dispatcher\n\n"
                f"{caller_context.strip()}\n"
            )
        else:
            context_block = ""
        return render_template(
            template,
            ticket_id=ticket_id,
            repo_path=repo_path,
            workspace_path=workspace_path,
            branch=branch,
            attempt=str(attempt),
            run_id=str(run_id),
            caller_context=context_block,
        )

    @staticmethod
    def _build_spike_prompt(
        *,
        ticket: dict[str, Any],
        repo_path: str,
        workspace_path: str,
        attempt: int,
        run_id: int,
        caller_context: str | None = None,
    ) -> str:
        context = caller_context.strip() if caller_context and caller_context.strip() else "None."
        return f"""You are a Relay Runner research-spike worker.

Investigate the bounded question in ticket {ticket['id']} and return only the structured result required by the provider output schema.

- Run: {run_id} (attempt {attempt})
- Source repository: {repo_path}
- Read-only detached snapshot: {workspace_path}
- Allowed evidence: files and Git history inside the snapshot, plus the refined ticket and dispatcher context below.
- Forbidden: edits, file creation, Git mutations, network access, desktop/app control, messages, purchases, deletion, or any other external side effect.
- Do not expose chain-of-thought, raw provider transcript, credentials, or unrelated private data.
- If you try a forbidden mutation, record it in `mutation_attempts`; the daemon will fail the run visibly.
- Conclusions must cite concise local evidence and separate uncertainties from recommendations.

## Refined ticket

Title: {ticket['title']}

{str(ticket.get('body') or '').strip()}

## Dispatcher context

{context}
"""

    def _effective_worker_agent(self) -> tuple[str, str, dict[str, Any]]:
        orch_cfg = self.cfg.get("orchestrator", {}) if isinstance(self.cfg.get("orchestrator"), dict) else {}
        explicit_agent = str(orch_cfg.get("agent") or "").strip()
        general = self.cfg.get("general", {}) if isinstance(self.cfg.get("general"), dict) else {}
        if explicit_agent:
            kind = _agent_kind(explicit_agent)
        else:
            loader = getattr(self, "config_loader", None)
            if loader is not None:
                try:
                    current_cfg = loader()
                    if isinstance(current_cfg, dict) and isinstance(current_cfg.get("general"), dict):
                        general = current_cfg["general"]
                        self.cfg["general"] = general
                except Exception as e:  # noqa: BLE001 - dispatch can still use startup config.
                    print(f"[orchestrator] could not reload config for dispatch: {e}", file=sys.stderr)
            kind = _provider_from_general(general, self.agent_kind)

        if kind == self.agent_kind:
            return kind, self.agent_bin, general
        return kind, _find_agent_bin(kind), general

    def _queue_drain_store(self) -> QueueDrainStore | None:
        return getattr(self, "queue_drains", None)

    def _queue_drain_quiescence_seconds(self) -> float:
        return float(getattr(self, "queue_drain_quiescence_seconds", QUEUE_DRAIN_QUIESCENCE_SECONDS))

    def _max_concurrent_workers(self) -> int:
        return max(0, int(getattr(self, "max_concurrent_workers", 0) or 0))

    def _capacity_wait_reason(self, *, repo_path: str) -> tuple[str, float] | None:
        max_workers = self._max_concurrent_workers()
        if max_workers <= 0:
            return None
        active = self.runs.active_count(repo_path)
        if active < max_workers:
            return None
        return (
            f"capacity wait: {active}/{max_workers} implementation worker slot(s) active",
            time.time() + QUEUE_DRAIN_MONITOR_INTERVAL_SECONDS,
        )

    def _repo_runs(self, repo_path: str) -> list[dict[str, Any]]:
        try:
            return self.runs.list_for_repo(repo_path, limit=5000)
        except AttributeError:
            return [
                run for run in self.runs.list(limit=5000)
                if str(Path(str(run.get("repo_path") or "")).expanduser().resolve()) == str(Path(repo_path).expanduser().resolve())
            ]

    @staticmethod
    def _latest_runs_by_ticket(runs: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
        latest: dict[str, dict[str, Any]] = {}
        for run in sorted(runs, key=lambda item: int(item.get("id") or 0), reverse=True):
            ticket_id = str(run.get("ticket_id") or "").upper()
            if ticket_id and ticket_id not in latest:
                latest[ticket_id] = run
        return latest

    def _local_run_owner(self, run_id: int, state: str) -> Any | None:
        if state == "Reviewing":
            workers = getattr(self, "_review_workers", {})
            lock = getattr(self, "_review_workers_lock", None)
        else:
            workers = getattr(self, "_workers", {})
            lock = getattr(self, "_workers_lock", None)
        if lock is None:
            return workers.get(run_id)
        with lock:
            return workers.get(run_id)

    def _run_abandoned(self, run: dict[str, Any]) -> bool:
        state = str(run.get("state") or "")
        if state not in {"Claimed", "Running", "Reviewing"}:
            return False
        try:
            run_id = int(run.get("id"))
        except (TypeError, ValueError):
            return False
        owner = self._local_run_owner(run_id, state)
        if owner is not None:
            proc = getattr(owner, "proc", None)
            if proc is None or proc.poll() is None:
                return False
        # A claim without a pid is still in the dispatch handoff window. If the
        # daemon restarts during that window, reconcile_on_startup recovers it.
        if state == "Claimed" and not run.get("pid"):
            return False
        return not _process_is_alive(run.get("pid"))

    @staticmethod
    def _run_progress_signature(run: dict[str, Any]) -> tuple[Any, ...]:
        workspace_path = str(run.get("workspace_path") or "")
        head = ""
        status = ""
        if workspace_path:
            head = _git_head(workspace_path) or ""
            result = _git(
                workspace_path,
                "status",
                "--porcelain=v1",
                "--untracked-files=normal",
                check=False,
            )
            if result.returncode == 0:
                status = result.stdout or ""

        log_size = -1
        log_mtime_ns = -1
        raw_log_path = str(run.get("log_path") or "")
        if raw_log_path:
            try:
                log_stat = Path(raw_log_path).stat()
                log_size = log_stat.st_size
                log_mtime_ns = log_stat.st_mtime_ns
            except OSError:
                pass

        return (
            str(run.get("activity") or ""),
            head,
            status,
            log_size,
            log_mtime_ns,
        )

    def _health_check_interval(self) -> float:
        return max(
            1.0,
            float(
                getattr(
                    self,
                    "worker_health_check_seconds",
                    DEFAULT_WORKER_HEALTH_CHECK_SECONDS,
                )
            ),
        )

    @staticmethod
    def _health_check_window_label(seconds: float) -> str:
        minutes = seconds / 60.0
        if minutes.is_integer():
            value = int(minutes)
            return f"{value} minute" if value == 1 else f"{value} minutes"
        return f"{seconds:g} seconds"

    def _health_tracking(self) -> tuple[dict[int, dict[str, Any]], threading.Lock]:
        health = getattr(self, "_run_health", None)
        if health is None:
            health = {}
            self._run_health = health
        lock = getattr(self, "_run_health_lock", None)
        if lock is None:
            lock = threading.Lock()
            self._run_health_lock = lock
        return health, lock

    def _forget_run_health(self, run_id: int) -> None:
        health, lock = self._health_tracking()
        with lock:
            health.pop(run_id, None)

    def _observe_run_health(self, run: dict[str, Any], *, now: float) -> str | None:
        if not _process_is_alive(run.get("pid")):
            return None
        run_id = int(run["id"])
        interval = self._health_check_interval()
        health, lock = self._health_tracking()
        event_kind: str | None = None
        event_message: str | None = None
        queue_messenger = True

        with lock:
            previous = health.get(run_id)
            if previous is None:
                health[run_id] = {
                    "checked_at": now,
                    "signature": self._run_progress_signature(run),
                    "warning": None,
                }
                return None

            warning = previous.get("warning")
            if now - float(previous["checked_at"]) < interval:
                return str(warning) if warning else None

            signature = self._run_progress_signature(run)
            window = self._health_check_window_label(interval)
            if signature == previous.get("signature"):
                event_kind = "run-health-warning"
                event_message = (
                    f"{run['ticket_id']} run {run_id} is alive but has no observable "
                    f"progress in the last {window}"
                )
                # Keep the trace current every interval, but only speak when the
                # run first enters the warning state.
                queue_messenger = not bool(warning)
                warning = event_message
            else:
                event_kind = "run-health-check"
                event_message = (
                    f"{run['ticket_id']} run {run_id} is alive and made observable "
                    f"progress in the last {window}"
                )
                queue_messenger = False
                warning = None
            health[run_id] = {
                "checked_at": now,
                "signature": signature,
                "warning": warning,
            }

        if event_kind and event_message:
            kwargs: dict[str, Any] = {
                "ticket_id": run.get("ticket_id"),
                "run_id": run_id,
                "source": "orchestrator",
                "message": event_message,
                "repo_path": run.get("repo_path"),
                "provider_key": run.get("provider_key"),
            }
            if not queue_messenger:
                kwargs["queue_messenger"] = False
            self._emit_lifecycle(event_kind, **kwargs)
        return str(warning) if warning else None

    def _ensure_queue_drain_for_ticket(
        self,
        *,
        repo: Path,
        ticket: dict[str, Any],
        provider_key: str,
        target_branch: str,
        trigger: str,
    ) -> dict[str, Any] | None:
        store = self._queue_drain_store()
        if store is None or ticket.get("canceled") or ticket.get("draft"):
            return None
        if ticket.get("status") not in {"ready", "in_progress"}:
            return None
        drain, created = store.ensure_active(
            repo_path=str(repo),
            target_branch=target_branch,
            provider_key=provider_key,
            observed_ticket_ids=[str(ticket["id"])],
            status_message=f"Queue drain started by {trigger}.",
        )
        if created:
            self._emit_lifecycle(
                "reasoning-summary",
                message=f"Started queue drain {drain['id']} for {ticket['id']}.",
                repo_path=str(repo),
                provider_key=provider_key,
            )
        return drain

    def _queue_drain_candidate_ids(
        self,
        *,
        tickets: list[dict[str, Any]],
        runs_by_ticket: dict[str, dict[str, Any]],
        active_drain: dict[str, Any] | None,
    ) -> list[str]:
        by_id = {str(ticket["id"]).upper(): ticket for ticket in tickets}
        observed = set(active_drain.get("observed_ticket_ids", []) if active_drain else [])
        for ticket in tickets:
            ticket_id = str(ticket["id"]).upper()
            if ticket.get("canceled") or ticket.get("draft"):
                continue
            if ticket.get("status") in {"ready", "in_progress", VERIFICATION_BLOCKED_STATUS}:
                observed.add(ticket_id)
        for ticket_id, run in runs_by_ticket.items():
            state = str(run.get("state") or "")
            ticket = by_id.get(ticket_id)
            if ticket and ticket.get("status") == "done":
                continue
            if state in set(self.runs.ACTIVE_STATES) | set(REVIEW_BLOCKING_STATES):
                observed.add(ticket_id)

        # Dependency predecessors are part of the drain only when an observed
        # ticket is waiting on them; unrelated backlog remains outside the goal.
        expanded = set(observed)
        for ticket_id in list(observed):
            ticket = by_id.get(ticket_id)
            if not ticket:
                continue
            for dep_id in ticket.get("depends_on", []):
                dep = by_id.get(str(dep_id).upper())
                if dep and dep.get("status") != "done":
                    expanded.add(str(dep_id).upper())
        return sorted(expanded)

    def _blocked_item(
        self,
        ticket_id: str,
        *,
        reason: str,
        owner: str = "human",
        next_step: str | None = None,
        run_id: int | None = None,
        unresolved_dependencies: list[str] | None = None,
    ) -> dict[str, Any]:
        return {
            "ticket_id": ticket_id,
            "state": "blocked",
            "run_id": run_id,
            "reason": reason,
            "blocker_owner": owner,
            "blocker_next_step": next_step or reason,
            "unresolved_dependencies": unresolved_dependencies or [],
        }

    def _classify_queue_drain_item(
        self,
        *,
        repo: Path,
        ticket_id: str,
        ticket: dict[str, Any] | None,
        all_tickets: list[dict[str, Any]],
        latest_run: dict[str, Any] | None,
        skip: dict[str, Any] | None,
        drive_reviews: bool,
        now: float,
    ) -> dict[str, Any]:
        if ticket is None:
            return self._blocked_item(
                ticket_id,
                reason="ticket file missing",
                next_step=f"Restore .orchestrator/{ticket_id}.md or cancel the drain.",
            )

        if ticket.get("canceled"):
            return {
                "ticket_id": ticket_id,
                "state": "canceled",
                "reason": "ticket is canceled",
                "unresolved_dependencies": [],
            }

        by_id = {str(item["id"]).upper(): item for item in all_tickets}
        unresolved = [
            dep_id for dep_id in ticket.get("depends_on", [])
            if not by_id.get(str(dep_id).upper()) or by_id[str(dep_id).upper()].get("status") != "done"
        ]
        if unresolved:
            return {
                "ticket_id": ticket_id,
                "state": "dependency_waiting",
                "reason": f"waiting on {', '.join(unresolved)}",
                "unresolved_dependencies": unresolved,
                "blocker_owner": "dependency",
                "blocker_next_step": "Automatically resume when every predecessor is reviewed, merged, and done.",
            }

        run_state = str((latest_run or {}).get("state") or "")
        run_id = int(latest_run["id"]) if latest_run and latest_run.get("id") is not None else None
        if latest_run and self._run_abandoned(latest_run):
            self._forget_run_health(run_id)
            if run_state == "Reviewing":
                self.runs.update(
                    run_id,
                    state="AwaitingReview",
                    last_error="review worker process is no longer running; ownership recovered",
                )
                with self._review_workers_lock:
                    self._review_workers.pop(run_id, None)
                run_state = "AwaitingReview"
            else:
                self.runs.update(
                    run_id,
                    state="Stalled",
                    last_error="worker process is no longer running; ownership recovered",
                    ended=True,
                    exit_code=-1,
                )
                latest_run = self.runs.get(run_id)
                run_state = "Stalled"

        health_warning = None
        if latest_run and run_state in set(self.runs.ACTIVE_STATES) | {"Reviewing"}:
            health_warning = self._observe_run_health(latest_run, now=now)

        if run_state in self.runs.ACTIVE_STATES:
            return {
                "ticket_id": ticket_id,
                "state": "active",
                "run_id": run_id,
                "reason": health_warning or run_state,
                "unresolved_dependencies": [],
            }

        if run_state == "Reviewing":
            return {
                "ticket_id": ticket_id,
                "state": "reviewing",
                "run_id": run_id,
                "reason": health_warning or "review/merge worker active",
                "unresolved_dependencies": [],
            }

        if run_state in {"AwaitingReview", "Succeeded"}:
            review_active = run_id in getattr(self, "_review_workers", {})
            if drive_reviews and not review_active:
                try:
                    result = self.dispatch_review_worker(run_id, source="queue-drain")
                    review_active = bool(result.get("review_dispatched") or result.get("review_already_active"))
                except Exception as e:  # noqa: BLE001 - leave a visible blocker.
                    return self._blocked_item(
                        ticket_id,
                        run_id=run_id,
                        reason=f"review dispatch failed: {e}",
                        next_step="Fix review worker launch or run review manually, then reconcile the drain.",
                    )
            return {
                "ticket_id": ticket_id,
                "state": "reviewing" if review_active else "awaiting_review",
                "run_id": run_id,
                "reason": "review worker scheduled" if review_active else "awaiting review dispatch",
                "next_action_at": now if not review_active else None,
                "unresolved_dependencies": [],
            }

        if run_state == "MergeConflict":
            return self._blocked_item(
                ticket_id,
                run_id=run_id,
                reason=str(latest_run.get("last_error") or "merge conflict"),
                next_step="Resolve the merge conflict or request an explicit retry.",
            )

        if ticket.get("status") == VERIFICATION_BLOCKED_STATUS:
            blocker = str(ticket.get("verification_blocker") or "").strip()
            resume = str(ticket.get("verification_resume") or "").strip()
            return self._blocked_item(
                ticket_id,
                run_id=run_id or ticket.get("run_id"),
                reason=blocker or "external verification is unavailable",
                owner="external_verification",
                next_step=(
                    resume
                    or "Change the external verification condition, then explicitly resume this run."
                ),
            )

        if ticket.get("status") == "done":
            if latest_run and run_state not in {"Merged", ""}:
                return self._blocked_item(
                    ticket_id,
                    run_id=run_id,
                    reason=f"source ticket is done but latest run is {run_state}",
                    next_step="Inspect the run and merge evidence before completing the drain.",
                )
            return {
                "ticket_id": ticket_id,
                "state": "done",
                "run_id": run_id,
                "reason": "source ticket is done",
                "unresolved_dependencies": [],
            }

        if skip:
            reason = str(skip.get("reason") or "")
            error = str(skip.get("error") or "")
            if reason == "capacity_wait":
                return {
                    "ticket_id": ticket_id,
                    "state": "scheduled",
                    "run_id": skip.get("run_id"),
                    "reason": skip.get("message") or "waiting for worker capacity",
                    "next_action_at": skip.get("next_action_at"),
                    "unresolved_dependencies": [],
                }
            if reason == "dispatch_failed":
                if "backoff active" in error:
                    next_action_at = None
                    if latest_run and latest_run.get("ended_at") is not None:
                        try:
                            next_action_at = float(latest_run["ended_at"]) + AUTO_DISPATCH_BACKOFF_SECONDS
                        except (TypeError, ValueError):
                            next_action_at = now + AUTO_DISPATCH_BACKOFF_SECONDS
                    return {
                        "ticket_id": ticket_id,
                        "state": "scheduled",
                        "run_id": run_id,
                        "reason": error,
                        "next_action_at": next_action_at or now + AUTO_DISPATCH_BACKOFF_SECONDS,
                        "unresolved_dependencies": [],
                    }
                return self._blocked_item(
                    ticket_id,
                    run_id=run_id,
                    reason=error or "dispatch failed",
                    next_step="Fix the dispatch blocker and explicitly redispatch or reconcile the drain.",
                )
            if reason == "run_id_present":
                return self._blocked_item(
                    ticket_id,
                    run_id=skip.get("run_id"),
                    reason="ticket has run_id but no live/mergeable run was found",
                    next_step="Inspect the recorded run_id, reset the ticket, or explicitly redispatch.",
                )

        if run_state in {"Failed", "Stalled"}:
            blocker = self._auto_dispatch_blocker(
                ticket_id=ticket_id,
                repo_path=str(repo),
                source="ready-sweeper",
            )
            if blocker:
                if "backoff active" in blocker:
                    next_action_at = now + AUTO_DISPATCH_BACKOFF_SECONDS
                    if latest_run and latest_run.get("ended_at") is not None:
                        try:
                            next_action_at = float(latest_run["ended_at"]) + AUTO_DISPATCH_BACKOFF_SECONDS
                        except (TypeError, ValueError):
                            pass
                    return {
                        "ticket_id": ticket_id,
                        "state": "scheduled",
                        "run_id": run_id,
                        "reason": blocker,
                        "next_action_at": next_action_at,
                        "unresolved_dependencies": [],
                    }
                return self._blocked_item(
                    ticket_id,
                    run_id=run_id,
                    reason=blocker,
                    next_step="Fix the last error and explicitly redispatch the ticket.",
                )

        if ticket.get("status") == "ready":
            return {
                "ticket_id": ticket_id,
                "state": "scheduled",
                "reason": "ready for automatic dispatch",
                "next_action_at": now,
                "unresolved_dependencies": [],
            }

        if ticket.get("status") == "in_progress":
            return self._blocked_item(
                ticket_id,
                run_id=ticket.get("run_id"),
                reason="ticket is in progress without a live or reviewable run",
                next_step="Inspect the partial work, mark it ready again, or cancel it.",
            )

        return {
            "ticket_id": ticket_id,
            "state": "done" if ticket.get("status") == "done" else "scheduled",
            "run_id": run_id,
            "reason": f"ticket status {ticket.get('status')}",
            "unresolved_dependencies": [],
        }

    def _record_queue_drain_locked(
        self,
        *,
        repo: Path,
        trigger: str | None = None,
        sweep_result: dict[str, Any] | None = None,
        drive_reviews: bool = True,
    ) -> dict[str, Any] | None:
        store = self._queue_drain_store()
        if store is None:
            return None

        tickets = scan_repo(repo)
        runs = self._repo_runs(str(repo))
        runs_by_ticket = self._latest_runs_by_ticket(runs)
        runs_by_id = {
            int(run["id"]): run
            for run in runs
            if run.get("id") is not None
        }
        for ticket in tickets:
            if ticket.get("status") not in {"done", VERIFICATION_BLOCKED_STATUS}:
                continue
            try:
                linked_run = runs_by_id.get(int(ticket.get("run_id")))
            except (TypeError, ValueError):
                linked_run = None
            ticket_id = str(ticket.get("id") or "").upper()
            if linked_run and str(linked_run.get("ticket_id") or "").upper() == ticket_id:
                runs_by_ticket[ticket_id] = linked_run
        active_drain = store.active_for_repo(str(repo))
        observed_ids = self._queue_drain_candidate_ids(
            tickets=tickets,
            runs_by_ticket=runs_by_ticket,
            active_drain=active_drain,
        )
        if not active_drain and not observed_ids:
            return None

        provider_key = self.agent_kind
        try:
            provider_key = self._effective_worker_agent()[0]
        except Exception:
            provider_key = self.agent_kind
        target_branch = _git_text(str(repo), "branch", "--show-current") or self._resolve_default_branch(str(repo))
        drain, created = store.ensure_active(
            repo_path=str(repo),
            target_branch=target_branch,
            provider_key=provider_key,
            observed_ticket_ids=observed_ids,
            status_message=f"Queue drain started by {trigger or 'reconcile'}.",
        )
        if active_drain:
            drain = store.append_observed(drain["id"], observed_ids) or drain
        elif created:
            self._emit_lifecycle(
                "reasoning-summary",
                message=f"Started queue drain {drain['id']}.",
                repo_path=str(repo),
                provider_key=provider_key,
            )

        tickets_by_id = {str(ticket["id"]).upper(): ticket for ticket in tickets}
        observed_ids = sorted(set(drain.get("observed_ticket_ids", [])) | set(observed_ids))
        skip_by_id = {
            str(item.get("ticket_id") or "").upper(): item
            for item in (sweep_result or {}).get("skipped", [])
            if item.get("ticket_id")
        }
        items = [
            self._classify_queue_drain_item(
                repo=repo,
                ticket_id=ticket_id,
                ticket=tickets_by_id.get(ticket_id),
                all_tickets=tickets,
                latest_run=runs_by_ticket.get(ticket_id),
                skip=skip_by_id.get(ticket_id),
                drive_reviews=drive_reviews,
                now=time.time(),
            )
            for ticket_id in observed_ids
        ]
        store.update_items(drain["id"], items)

        blocking = [item for item in items if item.get("state") == "blocked"]
        unfinished = [
            item for item in items
            if item.get("state") not in {"done", "canceled"}
        ]
        quiescent_since = drain.get("quiescent_since")
        if blocking:
            first = blocking[0]
            message = (
                f"Queue drain blocked on {first['ticket_id']}: "
                f"{first.get('blocker_next_step') or first.get('reason')}"
            )
            return store.update_state(
                drain["id"],
                state="blocked",
                provider_goal_state="blocked",
                status_message=message,
                quiescent_since=None,
            )

        if unfinished:
            state = "active" if any(item.get("state") in {"active", "reviewing", "awaiting_review", "scheduled"} for item in unfinished) else "waiting"
            message = f"Queue drain waiting on {len(unfinished)} ticket(s)."
            return store.update_state(
                drain["id"],
                state=state,
                provider_goal_state="active",
                status_message=message,
                quiescent_since=None,
            )

        now = time.time()
        if quiescent_since is None:
            return store.update_state(
                drain["id"],
                state="waiting",
                provider_goal_state="active",
                status_message=(
                    "Queue drain is quiescent; verifying for "
                    f"{self._queue_drain_quiescence_seconds():g}s before completion."
                ),
                quiescent_since=now,
            )
        try:
            quiet_for = now - float(quiescent_since)
        except (TypeError, ValueError):
            quiet_for = 0.0
        if quiet_for < self._queue_drain_quiescence_seconds():
            return store.update_state(
                drain["id"],
                state="waiting",
                provider_goal_state="active",
                status_message="Queue drain is still in the quiescence window.",
                quiescent_since=float(quiescent_since),
            )

        completed = store.update_state(
            drain["id"],
            state="completed",
            provider_goal_state="completed",
            status_message=f"Queue drain completed after {len(items)} observed ticket(s).",
            quiescent_since=float(quiescent_since),
            complete=True,
        )
        self._emit_lifecycle(
            "reasoning-summary",
            message=f"Queue drain {drain['id']} completed.",
            repo_path=str(repo),
            provider_key=provider_key,
        )
        return completed

    def reconcile_queue_drain(self, *, repo_path: str, trigger: str | None = None) -> dict[str, Any]:
        if not repo_path:
            raise ValueError("repo_path is required")
        repo = Path(repo_path).expanduser().resolve()
        if not repo.is_dir() or not (repo / ".git").exists():
            raise ValueError(f"repo_path {repo} is not a git repository")
        with self._authoring_mutex():
            sweep = self._sweep_ready_tickets_locked(
                repo=repo,
                trigger=trigger or "queue-drain",
                record_drain=False,
            )
            drain = self._record_queue_drain_locked(
                repo=repo,
                trigger=trigger or "queue-drain",
                sweep_result=sweep,
                drive_reviews=True,
            )
        return {"repo_path": str(repo), "trigger": trigger, "sweep": sweep, "drain": drain}

    def reconcile_queue_drains(
        self,
        *,
        repo_paths: list[str] | None = None,
        trigger: str | None = None,
    ) -> dict[str, Any]:
        store = self._queue_drain_store()
        requested = [
            str(Path(path).expanduser().resolve())
            for path in (repo_paths or [])
            if str(path).strip()
        ]
        if not requested:
            requested = _registered_project_repo_paths(self.program_registry_path)
            if store is not None:
                requested.extend(store.active_repo_paths())
        seen: set[str] = set()
        projects: list[dict[str, Any]] = []
        for path in requested:
            if path in seen:
                continue
            seen.add(path)
            try:
                projects.append(self.reconcile_queue_drain(
                    repo_path=path,
                    trigger=trigger or "queue-drain-monitor",
                ))
            except (ValueError, RuntimeError) as e:
                projects.append({"repo_path": path, "error": str(e)})
        return {"trigger": trigger, "projects": projects}

    def list_queue_drains(
        self,
        *,
        repo_path: str | None = None,
        include_terminal: bool = False,
        limit: int = 20,
    ) -> list[dict[str, Any]]:
        store = self._queue_drain_store()
        if store is None:
            return []
        return store.list(repo_path=repo_path, include_terminal=include_terminal, limit=limit)

    def cancel_queue_drain(self, drain_id: str, *, reason: str | None = None) -> dict[str, Any]:
        store = self._queue_drain_store()
        if store is None:
            raise ValueError("queue drain store is unavailable")
        result = store.cancel(drain_id, reason=reason)
        if result is None:
            raise ValueError(f"unknown queue drain {drain_id}")
        self._emit_lifecycle(
            "reasoning-summary",
            message=f"Queue drain {drain_id} canceled.",
            repo_path=result.get("repo_path"),
            provider_key=result.get("provider_key"),
        )
        return {"queue_drain": result}

    def _auto_dispatch_blocker(
        self,
        *,
        ticket_id: str,
        repo_path: str,
        source: str,
    ) -> str | None:
        if source not in AUTO_DISPATCH_SOURCES:
            return None
        history = self.runs.recent_for_ticket(ticket_id, repo_path=repo_path, limit=MAX_AUTO_DISPATCH_ATTEMPTS)
        attempts = [run for run in history if int(run.get("attempt") or 0) > 0]
        if len(attempts) >= MAX_AUTO_DISPATCH_ATTEMPTS:
            return (
                f"automatic retry exhausted after {len(attempts)} attempts; "
                "fix the last error and explicitly redispatch the ticket"
            )

        latest = attempts[0] if attempts else None
        if not latest or latest.get("state") not in {"Failed", "Stalled"}:
            return None
        latest_error = str(latest.get("last_error") or "").strip()
        if _is_deterministic_dispatch_failure(latest_error):
            return (
                "automatic retry circuit open after deterministic failure: "
                f"{latest_error}; fix the root cause and explicitly redispatch the ticket"
            )
        ended_at = latest.get("ended_at")
        if ended_at is not None:
            try:
                age = time.time() - float(ended_at)
            except (TypeError, ValueError):
                age = AUTO_DISPATCH_BACKOFF_SECONDS
            if age < AUTO_DISPATCH_BACKOFF_SECONDS:
                remaining = max(1, int(AUTO_DISPATCH_BACKOFF_SECONDS - age))
                return f"automatic retry backoff active after attempt {latest.get('attempt')}; retry in {remaining}s"
        return None

    # -- API -----------------------------------------------------------------

    def _record_dispatch_refusal(
        self,
        *,
        ticket_id: str,
        repo_path: str,
        workspace_path: Path,
        branch: str,
        log_path: Path,
        reason: str,
        provider_key: str,
        sizing: dict[str, Any] | None = None,
        execution_mode: str = "implementation",
    ) -> dict | None:
        attempt = self.runs.next_attempt(ticket_id, repo_path=repo_path)
        metadata = {
            "provider_key": provider_key,
            "model_alias": None,
            "worker_model": None,
            "worker_effort": None,
            "worker_sizing_rationale": None,
            "worker_provider_notes": None,
        }
        if sizing:
            metadata.update(sizing)
        run_id = self.runs.insert(
            ticket_id=ticket_id,
            repo_path=repo_path,
            workspace_path=str(workspace_path),
            branch=branch,
            execution_mode=execution_mode,
            state="Failed",
            attempt=attempt,
            log_path=str(log_path),
            **metadata,
        )
        self.runs.update(run_id, last_error=reason, ended=True, exit_code=-1)
        self._emit_lifecycle(
            "run-failed",
            ticket_id=ticket_id,
            run_id=run_id,
            source="worker",
            repo_path=repo_path,
            provider_key=metadata.get("provider_key"),
        )
        return self.runs.get(run_id)

    def _record_queue_drain_after_event(
        self,
        *,
        repo_path: str | None,
        trigger: str,
        drive_reviews: bool = True,
    ) -> None:
        if not repo_path:
            return
        try:
            repo = Path(repo_path).expanduser().resolve()
            if repo.is_dir() and (repo / ".git").exists():
                self._record_queue_drain_locked(
                    repo=repo,
                    trigger=trigger,
                    drive_reviews=drive_reviews,
                )
        except Exception as e:  # noqa: BLE001 - caller outcome is already durable.
            print(f"[orchestrator] queue-drain record failed after {trigger}: {e}", file=sys.stderr)

    @staticmethod
    def _resolve_default_branch(repo_path: str) -> str:
        """Resolve the repo's default branch via `git symbolic-ref`. Falls back to 'main'."""
        result = _git(repo_path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD", check=False)
        if result.returncode == 0:
            out = result.stdout.strip()
            if out.startswith("origin/"):
                return out[len("origin/"):]
        return "main"

    def dispatch(
        self,
        *,
        ticket_id: str,
        repo_path: str,
        context: str | None = None,
        source: str = "direct",
        relay_command_seq: int | str | None = None,
        relay_command_id: str | None = None,
        relay_intent_id: str | None = None,
        project_scope_token: str | None = None,
        internally_confirmed_project_id: str | None = None,
    ) -> dict:
        if not ticket_id:
            raise ValueError("ticket_id is required")
        if not repo_path:
            raise ValueError("repo_path is required")
        _validate_relay_command(
            relay_command_seq,
            relay_command_id,
            relay_intent_id=relay_intent_id,
            mutation=_relay_mutation_metadata("dispatch_ticket", ticket_id=ticket_id),
        )

        repo = Path(repo_path).expanduser().resolve()
        if not repo.is_dir() or not (repo / ".git").exists():
            raise ValueError(f"repo_path {repo} is not a git repository")
        artifact_lifecycle = self._artifact_lifecycle(str(repo))
        if artifact_lifecycle is not None:
            artifact_lifecycle.validate_scope(
                project_scope_token,
                internally_confirmed_project_id=internally_confirmed_project_id,
            )
        ticket_file = repo / ".orchestrator" / f"{ticket_id}.md"
        if not ticket_file.is_file():
            raise ValueError(f"ticket {ticket_id} not found at {ticket_file}")
        try:
            ticket = read_ticket(ticket_file)
        except (OSError, TicketParseError) as e:
            raise ValueError(f"ticket {ticket_id} could not be read: {e}") from e
        execution_mode = _execution_mode(ticket.get("execution_mode"))
        if artifact_lifecycle is not None and execution_mode == SPIKE_EXECUTION_MODE:
            raise ValueError(
                "artifact lifecycle does not yet own branchless spike results; "
                "drain active runs and use the reversible legacy lifecycle for this spike"
            )
        if ticket.get("status") == VERIFICATION_BLOCKED_STATUS:
            raise ValueError(
                f"ticket {ticket_id} is verification blocked; use the explicit resume action "
                "after the external condition changes"
            )
        _notify_orchestration_trace(
            "dispatch-started",
            ticket_id=ticket_id,
            relay_command_seq=relay_command_seq,
            relay_command_id=str(relay_command_id or "") if relay_command_id else None,
        )

        sanitized = sanitize_identifier(ticket_id)
        branch = "" if execution_mode == SPIKE_EXECUTION_MODE else f"{self.branch_prefix}{sanitized}"
        workspace_base = self.workspace_root / workspace_slug(str(repo), ticket_id)
        workspace_path = workspace_base
        log_path = workspace_path / ".relay" / "run.log"
        base_branch = self._resolve_default_branch(str(repo))
        target_branch = _git_text(str(repo), "branch", "--show-current") or base_branch
        command_store = getattr(self, "orchestrator_commands", None)

        with self._dispatch_lock:
            worker_provider, worker_bin, general_config = self._effective_worker_agent()
            self._ensure_queue_drain_for_ticket(
                repo=repo,
                ticket=ticket,
                provider_key=worker_provider,
                target_branch=target_branch,
                trigger=source,
            )
            existing = self.runs.find_active(ticket_id, repo_path=str(repo))
            if existing:
                print(
                    f"[orchestrator] dispatch skipped for {ticket_id} from {source}: "
                    f"already active run {existing['id']}",
                    file=sys.stderr,
                )
                self._record_queue_drain_after_event(
                    repo_path=str(repo),
                    trigger=f"dispatch-{source}-already-active",
                    drive_reviews=False,
                )
                if relay_command_id and command_store and command_store.get_private(
                    str(relay_command_id),
                    intent_id=relay_intent_id,
                ):
                    command_store.update_status(
                        str(relay_command_id),
                        intent_id=relay_intent_id,
                        status="dispatched",
                        outcome="dispatch-already-active",
                        ticket_id=ticket_id,
                        status_message=f"{ticket_id} already has an active run.",
                    )
                return {"already_active": True, "run": existing}

            awaiting_merge = self.runs.find_awaiting_merge(ticket_id, repo_path=str(repo))
            if awaiting_merge:
                reason = (
                    f"ticket {ticket_id} already has succeeded run "
                    f"{awaiting_merge['id']} awaiting merge; merge "
                    f"{awaiting_merge['branch']} or explicitly reset the ticket before retrying"
                )
                print(
                    f"[orchestrator] dispatch skipped for {ticket_id} from {source}: {reason}",
                    file=sys.stderr,
                )
                self._record_queue_drain_after_event(
                    repo_path=str(repo),
                    trigger=f"dispatch-{source}-awaiting-merge",
                    drive_reviews=True,
                )
                if relay_command_id and command_store and command_store.get_private(
                    str(relay_command_id),
                    intent_id=relay_intent_id,
                ):
                    command_store.update_status(
                        str(relay_command_id),
                        intent_id=relay_intent_id,
                        status="dispatched",
                        outcome="dispatch-awaiting-merge",
                        ticket_id=ticket_id,
                        status_message=f"{ticket_id} already has a run awaiting merge.",
                    )
                return {
                    "already_active": True,
                    "awaiting_merge": True,
                    "reason": reason,
                    "run": awaiting_merge,
                }

            auto_blocker = self._auto_dispatch_blocker(
                ticket_id=ticket_id,
                repo_path=str(repo),
                source=source,
            )
            if auto_blocker:
                print(
                    f"[orchestrator] auto-dispatch held for {ticket_id} from {source}: {auto_blocker}",
                    file=sys.stderr,
                )
                self._record_queue_drain_after_event(
                    repo_path=str(repo),
                    trigger=f"dispatch-{source}-held",
                    drive_reviews=False,
                )
                raise RuntimeError(auto_blocker)

            applied_default_sizing = apply_default_worker_sizing(
                ticket,
                general_config,
                agent_kind=worker_provider,
            )
            if applied_default_sizing:
                if artifact_lifecycle is not None:
                    raw_fields = ticket.get("_raw_fields") or {}
                    artifact_lifecycle.update_worker_sizing(
                        ticket_id=ticket_id,
                        provider=worker_provider,
                        fields=raw_fields,
                    )
                    ticket = read_ticket(ticket_file)
                else:
                    write_ticket(ticket_file, ticket)

            try:
                sizing = resolve_worker_sizing(
                    ticket,
                    worker_provider,
                    general=general_config if _uses_inherited_worker_defaults(general_config) else {},
                )
            except ValueError as e:
                reason = str(e)
                self._record_dispatch_refusal(
                    ticket_id=ticket_id,
                    repo_path=str(repo),
                    workspace_path=workspace_path,
                    branch=branch,
                    log_path=log_path,
                    reason=reason,
                    provider_key=worker_provider,
                    sizing=raw_worker_sizing_metadata(ticket, worker_provider),
                    execution_mode=execution_mode,
                )
                print(
                    f"[orchestrator] dispatch refused for {ticket_id} from {source}: {reason}",
                    file=sys.stderr,
                )
                self._record_queue_drain_after_event(
                    repo_path=str(repo),
                    trigger=f"dispatch-{source}-refused",
                    drive_reviews=False,
                )
                raise ValueError(reason) from e

            # Pre-existing attempts: bump attempt number for THIS ticket.
            attempt = self.runs.next_attempt(ticket_id, repo_path=str(repo))
            if execution_mode == SPIKE_EXECUTION_MODE:
                workspace_path = Path(f"{workspace_base}-spike-{attempt}")
                log_path = (
                    self.workspace_root
                    / ".spike-runs"
                    / workspace_slug(str(repo), ticket_id)
                    / f"run-{attempt}.log"
                )

            try:
                if execution_mode == SPIKE_EXECUTION_MODE:
                    create_spike_workspace(
                        repo_path=str(repo),
                        workspace_path=workspace_path,
                        base_branch=base_branch,
                    )
                else:
                    create_worktree(
                        repo_path=str(repo),
                        workspace_path=workspace_path,
                        branch=branch,
                        base_branch=base_branch,
                    )
            except RuntimeError as e:
                # Pre-flight failure — record the attempt as Failed for visibility.
                run_id = self.runs.insert(
                    ticket_id=ticket_id,
                    repo_path=str(repo),
                    workspace_path=str(workspace_path),
                    branch=branch,
                    execution_mode=execution_mode,
                    state="Failed",
                    attempt=attempt,
                    log_path=str(log_path),
                    **sizing,
                )
                self.runs.update(run_id, last_error=str(e), ended=True, exit_code=-1)
                self._emit_lifecycle(
                    "run-failed",
                    ticket_id=ticket_id,
                    run_id=run_id,
                    source="worker",
                    repo_path=str(repo),
                    provider_key=sizing.get("provider_key"),
                )
                self._record_queue_drain_after_event(
                    repo_path=str(repo),
                    trigger=f"dispatch-{source}-worktree-failed",
                    drive_reviews=False,
                )
                raise

            try:
                if execution_mode != SPIKE_EXECUTION_MODE and artifact_lifecycle is None:
                    _materialize_ticket_snapshot(
                        ticket_file=ticket_file,
                        workspace_path=workspace_path,
                        ticket_id=ticket_id,
                    )
            except RuntimeError as e:
                run_id = self.runs.insert(
                    ticket_id=ticket_id,
                    repo_path=str(repo),
                    workspace_path=str(workspace_path),
                    branch=branch,
                    execution_mode=execution_mode,
                    state="Failed",
                    attempt=attempt,
                    log_path=str(log_path),
                    **sizing,
                )
                self.runs.update(run_id, last_error=str(e), ended=True, exit_code=-1)
                self._emit_lifecycle(
                    "run-failed",
                    ticket_id=ticket_id,
                    run_id=run_id,
                    source="worker",
                    repo_path=str(repo),
                    provider_key=sizing.get("provider_key"),
                )
                self._record_queue_drain_after_event(
                    repo_path=str(repo),
                    trigger=f"dispatch-{source}-snapshot-failed",
                    drive_reviews=False,
                )
                raise

            run_id = self.runs.insert(
                ticket_id=ticket_id,
                repo_path=str(repo),
                workspace_path=str(workspace_path),
                branch=branch,
                execution_mode=execution_mode,
                state="Claimed",
                attempt=attempt,
                log_path=str(log_path),
                **sizing,
            )
            if artifact_lifecycle is not None and execution_mode != SPIKE_EXECUTION_MODE:
                try:
                    artifact_lifecycle.claim_and_materialize(
                        ticket_id=ticket_id,
                        run_id=run_id,
                        provider=worker_provider,
                        workspace_path=workspace_path,
                    )
                except Exception as error:  # noqa: BLE001 - publish a bounded terminal outcome.
                    reason = f"artifact lifecycle snapshot failed: {error}"
                    try:
                        artifact_lifecycle.record_failure(
                            run_id=run_id,
                            ticket_id=ticket_id,
                            provider=worker_provider,
                            reason=reason,
                        )
                    except Exception as lifecycle_error:  # noqa: BLE001
                        reason += f"; lifecycle recovery failed: {lifecycle_error}"
                    artifact_lifecycle.cleanup_snapshot(workspace_path)
                    removed, cleanup_error = remove_worktree(str(repo), workspace_path)
                    delete_branch(str(repo), branch)
                    if not removed or cleanup_error:
                        reason += f"; {cleanup_error or 'worker worktree cleanup failed'}"
                    self.runs.update(
                        run_id,
                        state="Failed",
                        last_error=reason,
                        ended=True,
                        exit_code=-1,
                    )
                    raise RuntimeError(reason) from error
            _notify_orchestration_trace(
                "dispatch-claimed",
                ticket_id=ticket_id,
                run_id=run_id,
                relay_command_seq=relay_command_seq,
                relay_command_id=str(relay_command_id or "") if relay_command_id else None,
            )

            if execution_mode == SPIKE_EXECUTION_MODE:
                ticket["status"] = "in_progress"
                ticket["run_id"] = run_id
                try:
                    commit_daemon_ticket_update(
                        repo=repo,
                        ticket_path=ticket_file,
                        ticket=ticket,
                        message=f"chore({ticket_id}): start spike run {run_id}",
                    )
                except RuntimeError as e:
                    removed, cleanup_error = remove_spike_workspace(workspace_path)
                    reason = str(e)
                    if cleanup_error:
                        reason += f"; {cleanup_error}"
                    self.runs.update(
                        run_id,
                        state="Failed",
                        last_error=reason,
                        ended=True,
                        exit_code=-1,
                    )
                    raise
                try:
                    log_path.parent.mkdir(parents=True, exist_ok=True)
                    result_schema_path = log_path.parent / f"run-{attempt}-result.schema.json"
                    result_schema_path.write_text(json.dumps(SPIKE_RESULT_SCHEMA, indent=2))
                    workflow_path = None
                    prompt = self._build_spike_prompt(
                        ticket=ticket,
                        repo_path=str(repo),
                        workspace_path=str(workspace_path),
                        attempt=attempt,
                        run_id=run_id,
                        caller_context=context,
                    )
                except (OSError, RuntimeError) as e:
                    reason = f"spike launch preparation failed: {e}"
                    try:
                        self._spike_ticket_update(
                            self.runs.get(run_id) or {},
                            result=None,
                            incomplete_reason=reason,
                        )
                    except (OSError, RuntimeError, TicketParseError, ValueError) as reset_error:
                        reason += f"; ticket reset failed: {reset_error}"
                    removed, cleanup_error = remove_spike_workspace(workspace_path)
                    if not removed or cleanup_error:
                        reason += f"; {cleanup_error or 'spike workspace still exists'}"
                    self.runs.update(
                        run_id,
                        state="Failed",
                        last_error=reason,
                        ended=True,
                        exit_code=-1,
                    )
                    raise RuntimeError(reason) from e
            else:
                workflow_path = (
                    Path(__file__).resolve().with_name("orchestrator_artifact_workflow.md")
                    if artifact_lifecycle is not None
                    else self._resolve_workflow_for_repo(str(repo))
                )
                prompt = self._build_prompt(
                    ticket_id=ticket_id,
                    repo_path=str(repo),
                    workspace_path=str(workspace_path),
                    branch=branch,
                    attempt=attempt,
                    run_id=run_id,
                    caller_context=context,
                    workflow_path=workflow_path,
                )

            run = self.runs.get(run_id) or {}
            run["artifact_lifecycle"] = artifact_lifecycle is not None
            if execution_mode == SPIKE_EXECUTION_MODE:
                run["result_schema_path"] = str(result_schema_path)
            worker = Worker(
                run_id=run_id, run=run, prompt=prompt, agent_bin=worker_bin,
                agent_kind=worker_provider, workflow_path=workflow_path,
                store=self.runs, log_path=log_path,
                on_complete=self._on_worker_complete,
                emit_lifecycle=self._emit_lifecycle,
                artifact_completion_validator=(
                    (
                        lambda start_head, lifecycle=artifact_lifecycle,
                        path=workspace_path, tid=ticket_id, rid=run_id,
                        provider=worker_provider: lifecycle.validate_worker_completion(
                            workspace_path=path,
                            ticket_id=tid,
                            run_id=rid,
                            provider=provider,
                            start_head=start_head,
                        )
                    )
                    if artifact_lifecycle is not None
                    else None
                ),
            )
            with self._workers_lock:
                self._workers[run_id] = worker
            worker.start()

            print(
                f"[orchestrator] dispatch claimed {ticket_id} from {source}: "
                f"run {run_id} ({worker_provider})",
                file=sys.stderr,
            )

        run = self.runs.get(run_id)
        self._record_queue_drain_after_event(
            repo_path=str(repo),
            trigger=f"dispatch-{source}-claimed",
            drive_reviews=False,
        )
        if relay_command_id and command_store and command_store.get_private(
            str(relay_command_id),
            intent_id=relay_intent_id,
        ):
            command_store.update_status(
                str(relay_command_id),
                intent_id=relay_intent_id,
                status="dispatched",
                outcome="ticket-dispatched",
                ticket_id=ticket_id,
                status_message=f"Dispatched {ticket_id}.",
            )
        return {"already_active": False, "run": run}

    def _spike_ticket_update(
        self,
        run: dict[str, Any],
        *,
        result: dict[str, Any] | None,
        incomplete_reason: str | None = None,
    ) -> None:
        repo = Path(str(run["repo_path"])).expanduser().resolve()
        ticket_path = repo / ".orchestrator" / f"{run['ticket_id']}.md"
        ticket = read_ticket(ticket_path)
        if ticket.get("execution_mode") != SPIKE_EXECUTION_MODE:
            raise RuntimeError("canonical ticket no longer has spike execution mode")
        if ticket.get("status") != "in_progress" or ticket.get("run_id") != run["id"]:
            raise RuntimeError(
                "canonical spike ticket changed while the run was active; refusing overwrite"
            )
        existing_log = _body_section(ticket, "Run log")
        if result is not None:
            report = render_spike_report(
                result,
                run_id=int(run["id"]),
                attempt=int(run.get("attempt") or 1),
                provider=str(run.get("provider_key") or "unknown"),
            )
            ticket["body"] = _replace_markdown_section(
                str(ticket.get("body") or ""), "Spike report", report
            )
            log_entry = (
                f"- **Run {run['id']}** (attempt {run.get('attempt') or 1}) - "
                "branchless spike completed; findings persisted by the daemon."
            )
            ticket["status"] = "done"
            message = f"docs({run['ticket_id']}): record spike run {run['id']}"
        else:
            reason = _spike_text(
                incomplete_reason or "Spike did not produce a complete result.",
                field="incomplete_reason",
            )
            log_entry = (
                f"- **Run {run['id']}** (attempt {run.get('attempt') or 1}) - "
                f"branchless spike incomplete: {reason}"
            )
            ticket["status"] = "backlog"
            ticket["run_id"] = None
            message = f"docs({run['ticket_id']}): record incomplete spike run {run['id']}"
        run_log = "\n".join(item for item in (existing_log, log_entry) if item)
        ticket["body"] = _replace_markdown_section(
            str(ticket.get("body") or ""), "Run log", run_log
        )
        commit_daemon_ticket_update(
            repo=repo,
            ticket_path=ticket_path,
            ticket=ticket,
            message=message,
        )

    def _recover_stalled_spikes(self) -> None:
        for run in self.runs.list(state="Stalled", limit=5000):
            if run.get("execution_mode") != SPIKE_EXECUTION_MODE:
                continue
            try:
                self._spike_ticket_update(
                    run,
                    result=None,
                    incomplete_reason=str(run.get("last_error") or "Spike stopped during daemon restart."),
                )
            except (OSError, RuntimeError, TicketParseError, ValueError) as e:
                self.runs.update(run["id"], last_error=f"{run.get('last_error')}; recovery: {e}")
            remove_spike_workspace(Path(str(run.get("workspace_path") or "")))

    def _on_worker_complete(self, run_id: int) -> None:
        with self._workers_lock:
            worker = self._workers.pop(run_id, None)
        self._forget_run_health(run_id)
        run = self.runs.get(run_id)
        if not run:
            return
        if run.get("execution_mode") == SPIKE_EXECUTION_MODE:
            try:
                if run.get("state") == "SpikeResultReady" and worker and worker.spike_result:
                    self._spike_ticket_update(run, result=worker.spike_result)
                    self.runs.update(
                        run_id,
                        state=SPIKE_COMPLETED_RUN_STATE,
                        last_error="",
                    )
                    self._emit_lifecycle(
                        "run-succeeded",
                        ticket_id=run.get("ticket_id"),
                        run_id=run_id,
                        source="orchestrator",
                        message=f"{run.get('ticket_id')} spike findings are ready",
                        repo_path=run.get("repo_path"),
                        provider_key=run.get("provider_key"),
                    )
                else:
                    reason = str(run.get("last_error") or f"spike ended in {run.get('state')}")
                    self._spike_ticket_update(run, result=None, incomplete_reason=reason)
            except (OSError, RuntimeError, TicketParseError, ValueError) as e:
                self.runs.update(
                    run_id,
                    state="Failed",
                    last_error=f"spike result persistence failed: {e}",
                )
            finally:
                removed, error = remove_spike_workspace(Path(str(run["workspace_path"])))
                if not removed or error:
                    current = self.runs.get(run_id) or run
                    cleanup = error or "spike workspace still exists"
                    self.runs.update(
                        run_id,
                        last_error="; ".join(
                            item for item in (str(current.get("last_error") or "").strip(), cleanup)
                            if item
                        ),
                    )
            self._record_queue_drain_after_event(
                repo_path=run.get("repo_path"),
                trigger="spike-completion",
                drive_reviews=False,
            )
            return
        artifact_lifecycle = self._artifact_lifecycle(str(run.get("repo_path") or ""))
        if artifact_lifecycle is not None:
            raw_log_path = str(run.get("log_path") or "")
            if raw_log_path:
                artifact_lifecycle.cap_local_log(Path(raw_log_path))
            if run.get("state") in {"Failed", "Canceled", "Stalled"}:
                reason = str(run.get("last_error") or f"run ended in {run.get('state')}")
                try:
                    artifact_lifecycle.record_failure(
                        run_id=run_id,
                        ticket_id=str(run.get("ticket_id") or ""),
                        provider=str(run.get("provider_key") or ""),
                        reason=reason,
                        canceled=run.get("state") == "Canceled",
                    )
                except Exception as error:  # noqa: BLE001 - preserve the worker ledger.
                    self.runs.update(
                        run_id,
                        last_error=f"{reason}; artifact lifecycle publication failed: {error}",
                    )
        if run.get("state") in {"AwaitingReview", "Succeeded"}:
            try:
                self.dispatch_review_worker(run_id, source="worker-completion")
            except Exception as e:  # noqa: BLE001 — keep the completed run reviewable
                self.runs.update(run_id, state="AwaitingReview", last_error=f"review dispatch failed: {e}")
                self._emit_lifecycle(
                    "run-review-needed",
                    ticket_id=run.get("ticket_id"),
                    run_id=run_id,
                    source="orchestrator",
                    message=f"{run.get('ticket_id')} run {run_id} review dispatch needs attention",
                    repo_path=run.get("repo_path"),
                    provider_key=run.get("provider_key"),
                )
                print(f"[orchestrator] review dispatch failed for run {run_id}: {e}", file=sys.stderr)
            self._record_queue_drain_after_event(
                repo_path=run.get("repo_path"),
                trigger="worker-completion",
                drive_reviews=False,
            )
            return
        # Dependency progression now happens only after the review worker
        # accepts and merges the implementation branch.
        self._record_queue_drain_after_event(
            repo_path=run.get("repo_path"),
            trigger="worker-completion",
            drive_reviews=False,
        )

    def _on_review_worker_complete(self, run_id: int) -> None:
        with self._review_workers_lock:
            self._review_workers.pop(run_id, None)
        self._forget_run_health(run_id)
        run = self.runs.get(run_id)
        if run:
            self._record_queue_drain_after_event(
                repo_path=run.get("repo_path"),
                trigger="review-worker-completion",
                drive_reviews=False,
            )

    def _build_review_prompt(
        self,
        run: dict,
        *,
        source: str,
        review_provider: str,
        context: str | None = None,
    ) -> str:
        repo_path = str(run["repo_path"])
        branch = str(run["branch"])
        ticket_id = str(run["ticket_id"])
        run_id = int(run["id"])
        target_branch = _git_text(repo_path, "branch", "--show-current") or self._resolve_default_branch(repo_path)
        evidence = self.inspect_run_for_review(run_id)
        context_block = f"\n## Additional context\n\n{context.strip()}\n" if context and context.strip() else ""
        provider_notes = str(run.get("worker_provider_notes") or "none")
        return f"""You are a relay-runner review/merge sub-agent.

Review implementation worker run {run_id} for ticket {ticket_id}. The foreground orchestrator handed this to you so it does not perform the substantive review or merge itself.

## Context

- Source repo path: `{repo_path}`
- Target branch: `{target_branch}`
- Implementation worker branch: `{branch}`
- Implementation worker worktree: `{run.get("workspace_path")}`
- Implementation provider: `{run.get("provider_key") or "unknown"}`
- Review provider: `{review_provider}`
- Worker model: `{run.get("worker_model") or "unknown"}`
- Worker effort: `{run.get("worker_effort") or "unknown"}`
- Provider notes: {provider_notes}
- Dispatch source: `{source}`
{context_block}
## Evidence from the completed worker

### Branch commits
```text
{evidence.get("branch_commits") or "(none)"}
```

### Changed paths
```text
{evidence.get("branch_diff_name_status") or "(none)"}
```

### Diff stat
```text
{evidence.get("branch_diff_stat") or "(none)"}
```

### Worker run log
```text
{evidence.get("ticket_run_log") or "(none)"}
```

### Declared ticket outcome
```text
{evidence.get("ticket_status") or "(unknown)"}
```

### Worker log tail
```text
{evidence.get("log_tail") or "(none)"}
```

## What you must do

1. Confirm the source repo and implementation branch exist.
2. Inspect the worker branch changes against `{target_branch}`.
3. Run the appropriate verification for the changed files.
4. If the branch is acceptable, call the private daemon decision endpoint with `decision: accept`. A `verification_blocked` outcome is acceptable only when implementation is reviewable and the ticket names an exact external blocker plus explicit resume condition; accepting it merges useful work without closing the ticket or progressing dependents. If the work itself needs follow-up, call the same endpoint with `decision: retry` and a concise reason.

Use this command shape for the final decision:

```bash
python3 - <<'PY'
import json, urllib.request
body = json.dumps({{"decision": "accept"}}).encode()
request = urllib.request.Request(
    "http://127.0.0.1:{self.port}/v1/runs/{run_id}/review/decision",
    data=body,
    headers={{"Content-Type": "application/json"}},
    method="POST",
)
print(urllib.request.urlopen(request, timeout=30).read().decode())
PY
```

For a retry decision, send `{{"decision": "retry", "reason": "...", "redispatch": true}}`.

Do not edit tickets directly. Do not push. The daemon merge path publishes `done` or the reviewed `verification_blocked` state only after acceptance and merge succeeds.
"""

    def dispatch_review_worker(
        self,
        run_id: int,
        *,
        source: str = "direct",
        context: str | None = None,
    ) -> dict:
        run = self.runs.get(run_id)
        if not run:
            raise ValueError(f"unknown run_id {run_id}")
        if run.get("state") not in REVIEW_BLOCKING_STATES:
            raise ValueError(f"run {run_id} is not awaiting review")

        with self._review_workers_lock:
            if run_id in self._review_workers:
                return {"review_already_active": True, "run": self.runs.get(run_id)}

            review_provider, review_bin, _general_config = self._effective_worker_agent()
            artifact_lifecycle = self._artifact_lifecycle(str(run.get("repo_path") or ""))
            if artifact_lifecycle is not None:
                artifact_lifecycle.begin_review(
                    run_id=run_id,
                    provider=review_provider,
                )
            prompt = self._build_review_prompt(
                run,
                source=source,
                review_provider=review_provider,
                context=context,
            )
            raw_log_path = str(run.get("log_path") or "")
            log_path = Path(raw_log_path) if raw_log_path else Path(str(run["workspace_path"])) / ".relay" / "run.log"
            worker = ReviewWorker(
                run_id=run_id,
                run=run,
                prompt=prompt,
                agent_bin=review_bin,
                agent_kind=review_provider,
                store=self.runs,
                log_path=log_path,
                on_complete=self._on_review_worker_complete,
                emit_lifecycle=self._emit_lifecycle,
            )
            self._review_workers[run_id] = worker
            worker.start()

        print(
            f"[orchestrator] review worker dispatched for {run['ticket_id']} "
            f"run {run_id} from {source}: {review_provider}",
            file=sys.stderr,
        )
        return {"review_dispatched": True, "run": self.runs.get(run_id)}

    def _progress_dependents(self, *, repo_path: str, finished_ticket_id: str) -> None:
        """When a ticket is done in the source repo, dispatch dependents whose deps are done.

        Backlog dependents are promoted to the on-disk `ready` schema value
        only after every predecessor is actually `done` in the source repo.
        Dependents already in `ready` stay queued until this path sees every
        predecessor done, then use the same provider-neutral dispatch chokepoint
        as manually queued work.
        """
        with self._authoring_mutex():
            self._progress_dependents_locked(repo_path=repo_path, finished_ticket_id=finished_ticket_id)

    def _progress_dependents_locked(self, *, repo_path: str, finished_ticket_id: str) -> None:
        repo = Path(repo_path)
        all_tickets = scan_repo(repo)
        by_id = {t["id"]: t for t in all_tickets}
        finished = by_id.get(finished_ticket_id)
        if not finished or finished["status"] != "done":
            return
        dependents = [t for t in all_tickets if finished_ticket_id in t["depends_on"]]
        for dep in dependents:
            if dep["status"] not in ("backlog", "ready"):
                continue
            if not all_deps_done(dep, all_tickets):
                continue
            if dep["status"] == "backlog" and finished.get("execution_mode") == SPIKE_EXECUTION_MODE:
                # A research result informs refinement; it never authorizes a
                # downstream implementation ticket on the user's behalf.
                continue
            if dep["status"] == "backlog":
                dep["status"] = "ready"
                write_ticket(dep["_path"], dep)
                _notify_orchestration_trace(
                    "board-change",
                    ticket_id=dep["id"],
                )
            try:
                self.dispatch(ticket_id=dep["id"], repo_path=str(repo), source="dependency-progression")
            except (ValueError, RuntimeError) as e:
                # Daemon refused dispatch (e.g. file missing, already active);
                # the status flip stays — user can drag/redispatch manually.
                print(f"[orchestrator] auto-dispatch declined for {dep['id']}: {e}", file=sys.stderr)

    def _promote_unblocked_dependents(self, *, repo_path: str) -> list[str]:
        """Promote backlog dependents whose dependencies are done in the source repo."""
        repo = Path(repo_path)
        all_tickets = scan_repo(repo)
        by_id = {ticket["id"]: ticket for ticket in all_tickets}
        promoted: list[str] = []
        for ticket in all_tickets:
            if ticket["status"] != "backlog" or not ticket["depends_on"]:
                continue
            if not all_deps_done(ticket, all_tickets):
                continue
            if any(
                by_id.get(dep_id, {}).get("execution_mode") == SPIKE_EXECUTION_MODE
                for dep_id in ticket["depends_on"]
            ):
                continue
            ticket["status"] = "ready"
            write_ticket(ticket["_path"], ticket)
            promoted.append(ticket["id"])
            _notify_orchestration_trace(
                "board-change",
                ticket_id=ticket["id"],
            )
        return promoted

    def sweep_ready_tickets(
        self,
        *,
        repo_path: str,
        trigger: str | None = None,
        project_scope_token: str | None = None,
    ) -> dict:
        """Reconcile a repo board and dispatch eligible queued tickets.

        The app calls this repeatedly for the active project. It deliberately
        re-enters `dispatch()` for worker creation so Codex/Claude provider
        selection, worktree creation, and active-run idempotency stay in one
        chokepoint.
        """
        if not repo_path:
            raise ValueError("repo_path is required")

        repo = Path(repo_path).expanduser().resolve()
        if not repo.is_dir() or not (repo / ".git").exists():
            raise ValueError(f"repo_path {repo} is not a git repository")
        artifact_lifecycle = self._artifact_lifecycle(str(repo))
        if artifact_lifecycle is not None:
            artifact_lifecycle.validate_scope(project_scope_token)

        with self._authoring_mutex():
            return self._sweep_ready_tickets_locked(
                repo=repo,
                trigger=trigger,
                artifact_lifecycle=artifact_lifecycle,
            )

    def _sweep_ready_tickets_locked(
        self,
        *,
        repo: Path,
        trigger: str | None = None,
        record_drain: bool = True,
        artifact_lifecycle: ArtifactLifecycleCoordinator | None = None,
    ) -> dict:
        promoted = (
            []
            if artifact_lifecycle is not None
            else self._promote_unblocked_dependents(repo_path=str(repo))
        )
        all_tickets = scan_repo(repo)
        dispatched: list[dict[str, Any]] = []
        skipped: list[dict[str, Any]] = []

        def skip(ticket: dict[str, Any], reason: str, **extra: Any) -> None:
            entry = {"ticket_id": ticket["id"], "reason": reason}
            entry.update(extra)
            skipped.append(entry)

        for ticket in all_tickets:
            if ticket["status"] != "ready":
                skip(ticket, f"status:{ticket['status']}")
                continue
            if ticket["canceled"]:
                skip(ticket, "canceled")
                continue
            if ticket.get("draft"):
                skip(ticket, "draft")
                continue
            if ticket["run_id"] is not None:
                skip(ticket, "run_id_present", run_id=ticket["run_id"])
                continue
            if not all_deps_done(ticket, all_tickets):
                skip(ticket, "dependencies_not_done")
                continue

            capacity_wait = self._capacity_wait_reason(repo_path=str(repo))
            if capacity_wait is not None:
                message, next_action_at = capacity_wait
                skip(ticket, "capacity_wait", message=message, next_action_at=next_action_at)
                continue

            existing = self.runs.find_active(ticket["id"], repo_path=str(repo))
            if existing:
                skip(ticket, "already_active", run_id=existing["id"])
                continue

            awaiting_merge = self.runs.find_awaiting_merge(ticket["id"], repo_path=str(repo))
            if awaiting_merge:
                skip(
                    ticket,
                    "awaiting_merge",
                    run_id=awaiting_merge["id"],
                    branch=awaiting_merge["branch"],
                )
                continue

            try:
                dispatch_args: dict[str, Any] = {
                    "ticket_id": ticket["id"],
                    "repo_path": str(repo),
                    "source": "ready-sweeper",
                }
                if artifact_lifecycle is not None:
                    dispatch_args["internally_confirmed_project_id"] = (
                        artifact_lifecycle.store.project_id
                    )
                result = self.dispatch(**dispatch_args)
            except (ValueError, RuntimeError) as e:
                skip(ticket, "dispatch_failed", error=str(e))
                print(
                    f"[orchestrator] ready-sweeper dispatch failed for {ticket['id']}: {e}",
                    file=sys.stderr,
                )
                continue

            run = result.get("run") or {}
            run_id = run.get("id")
            if result.get("already_active"):
                reason = "awaiting_merge" if result.get("awaiting_merge") else "already_active"
                skip(ticket, reason, run_id=run_id)
                continue

            dispatched.append({"ticket_id": ticket["id"], "run_id": run_id})
            trigger_note = f" after {trigger}" if trigger else ""
            print(
                f"[orchestrator] ready-sweeper auto-dispatched {ticket['id']}"
                f"{trigger_note}: run {run_id}",
                file=sys.stderr,
            )

        result = {
            "repo_path": str(repo),
            "trigger": trigger,
            "promoted": promoted,
            "dispatched": dispatched,
            "skipped": skipped,
        }
        if record_drain:
            result["drain"] = self._record_queue_drain_locked(
                repo=repo,
                trigger=trigger,
                sweep_result=result,
                drive_reviews=True,
            )
        return result

    def sweep_program_ready_tickets(
        self,
        *,
        trigger: str | None = None,
        repo_paths: list[str] | None = None,
    ) -> dict:
        """Reconcile queued tickets across the requested registered projects.

        Program Workspace refresh uses this instead of requiring each repo
        to be opened. Each ticket still dispatches through `dispatch()`, so
        Codex/Claude launch behavior and active-run idempotency stay shared.
        """
        projects: list[dict[str, Any]] = []
        dispatched: list[dict[str, Any]] = []
        skipped: list[dict[str, Any]] = []
        registered_repo_paths = _registered_project_repo_paths(self.program_registry_path)
        if repo_paths is not None:
            requested_repo_paths = {
                str(Path(path).expanduser().resolve())
                for path in repo_paths
                if str(path).strip()
            }
            registered_repo_paths = [
                path for path in registered_repo_paths if path in requested_repo_paths
            ]
        for repo_path in registered_repo_paths:
            try:
                result = self.sweep_ready_tickets(
                    repo_path=repo_path,
                    trigger=trigger or "program-ready-sweep",
                )
            except (ValueError, RuntimeError) as e:
                entry = {"repo_path": repo_path, "error": str(e)}
                projects.append(entry)
                skipped.append(entry)
                continue

            projects.append(result)
            for item in result.get("dispatched", []):
                dispatched.append({"repo_path": result["repo_path"], **item})
            for item in result.get("skipped", []):
                skipped.append({"repo_path": result["repo_path"], **item})

        return {
            "trigger": trigger,
            "projects": projects,
            "dispatched": dispatched,
            "skipped": skipped,
        }

    def list_runs(self, state: str | None = None, limit: int = 100) -> list[dict]:
        return self.runs.list(state=state, limit=limit)

    def get_run(self, run_id: int) -> dict | None:
        return self.runs.get(run_id)

    def submit_worker_outcome(self, run_id: int, payload: dict[str, Any]) -> dict[str, Any]:
        run = self.runs.get(run_id)
        if not run:
            raise ValueError(f"unknown run_id {run_id}")
        if run.get("state") not in {"Claimed", "Running"}:
            raise ValueError(f"run {run_id} is not accepting a worker outcome")
        lifecycle = self._artifact_lifecycle(str(run.get("repo_path") or ""))
        if lifecycle is None:
            raise ValueError(f"run {run_id} uses the legacy ticket lifecycle")
        try:
            outcome = lifecycle.submit_outcome(
                run_id=run_id,
                ticket_id=str(run["ticket_id"]),
                provider=str(run.get("provider_key") or ""),
                payload=payload,
            )
        except ArtifactValidationError as error:
            raise ValueError(str(error)) from error
        return {
            "accepted": True,
            "outcome": {
                "schema_version": outcome.schema_version,
                "project_id": outcome.project_id,
                "ticket_id": outcome.ticket_id,
                "run_id": outcome.run_id,
                "provider": outcome.provider,
                "status": outcome.status.value,
                "summary": outcome.summary,
                "changed_paths": list(outcome.changed_paths),
                "verification": list(outcome.verification),
                "source_commit": outcome.source_commit,
                "verification_blocker": outcome.verification_blocker,
                "verification_resume": outcome.verification_resume,
            },
        }

    def inspect_run_for_review(self, run_id: int) -> dict:
        run = self.runs.get(run_id)
        if not run:
            raise ValueError(f"unknown run_id {run_id}")

        repo_path = str(run.get("repo_path") or "")
        workspace_text = str(run.get("workspace_path") or "")
        branch = str(run.get("branch") or "")
        ticket_id = str(run.get("ticket_id") or "")
        ticket_log = ""
        ticket_status = None
        if workspace_text:
            workspace_path = Path(workspace_text)
            try:
                ticket = read_ticket(workspace_path / ".orchestrator" / f"{ticket_id}.md")
                ticket_status = ticket.get("status")
                ticket_log = _ticket_run_log(str(ticket.get("body") or ""))
            except (OSError, TicketParseError):
                ticket_log = ""
        if ticket_status is None and repo_path:
            try:
                ticket = read_ticket(Path(repo_path) / ".orchestrator" / f"{ticket_id}.md")
                ticket_status = ticket.get("status")
                ticket_log = _ticket_run_log(str(ticket.get("body") or ""))
            except (OSError, TicketParseError):
                pass

        artifact_lifecycle = self._artifact_lifecycle(repo_path) if repo_path else None
        if artifact_lifecycle is not None:
            outcome = artifact_lifecycle.outcome(run_id)
            if outcome is not None:
                ticket_status = (
                    VERIFICATION_BLOCKED_STATUS
                    if outcome.status.value == VERIFICATION_BLOCKED_STATUS
                    else "done"
                )
                ticket_log = (
                    f"Structured outcome: {outcome.summary}\n"
                    f"Verification: {'; '.join(outcome.verification) or '(none)'}\n"
                    f"Source commit: {outcome.source_commit}"
                )

        return {
            "run": run,
            "review_needed": run.get("state") in REVIEW_BLOCKING_STATES,
            "ticket_status": ticket_status,
            "log_tail": _tail_text(Path(str(run.get("log_path") or ""))) if run.get("log_path") else "",
            "ticket_run_log": ticket_log,
            "branch_commits": _git_text(repo_path, "log", "--oneline", f"HEAD..{branch}") if repo_path and branch else "",
            "branch_diff_stat": _git_text(repo_path, "diff", "--stat", f"HEAD...{branch}") if repo_path and branch else "",
            "branch_diff_name_status": _git_text(repo_path, "diff", "--name-status", f"HEAD...{branch}") if repo_path and branch else "",
            "verification_evidence": (
                run.get("last_error")
                if ticket_status == VERIFICATION_BLOCKED_STATUS
                else "worker completion validation passed"
                if run.get("state") in REVIEW_BLOCKING_STATES
                else run.get("last_error")
            ),
        }

    def accept_worker_run(self, run_id: int) -> dict:
        run = self.runs.get(run_id)
        if not run:
            raise ValueError(f"unknown run_id {run_id}")
        if run.get("state") not in MERGEABLE_REVIEW_STATES:
            raise ValueError(f"run {run_id} is not awaiting review")

        repo_path = str(run["repo_path"])
        branch = str(run["branch"])
        ticket_id = str(run["ticket_id"])
        artifact_lifecycle = self._artifact_lifecycle(repo_path)
        artifact_outcome = None
        if artifact_lifecycle is not None:
            artifact_outcome = artifact_lifecycle.outcome(run_id)
            if artifact_outcome is None:
                raise ValueError(f"run {run_id} has no structured artifact outcome")
            expected_status = (
                VERIFICATION_BLOCKED_STATUS
                if artifact_outcome.status.value == VERIFICATION_BLOCKED_STATUS
                else "done"
            )
            review_ticket = None
        else:
            workspace_ticket_path = (
                Path(str(run["workspace_path"])) / ".orchestrator" / f"{ticket_id}.md"
            )
            try:
                review_ticket = read_ticket(workspace_ticket_path)
            except (OSError, TicketParseError) as e:
                raise ValueError(f"could not read reviewed ticket for run {run_id}: {e}") from e
            expected_status = str(review_ticket.get("status") or "")
            if expected_status not in {"done", VERIFICATION_BLOCKED_STATUS}:
                raise ValueError(
                    f"run {run_id} ticket status {expected_status!r} is not a reviewable outcome"
                )

        status = _git(repo_path, "status", "--porcelain", check=False)
        if status.returncode != 0 or status.stdout.strip():
            reason = "source repo has uncommitted changes; refusing worker merge"
            if artifact_lifecycle is not None:
                try:
                    artifact_lifecycle.record_merge_conflict(
                        run_id=run_id,
                        ticket_id=ticket_id,
                        provider=str(run.get("provider_key") or ""),
                        reason=reason,
                    )
                except Exception as error:  # noqa: BLE001
                    reason += f"; artifact conflict publication failed: {error}"
            self.runs.update(run_id, state="MergeConflict", last_error=reason)
            self._emit_lifecycle(
                "run-failed",
                ticket_id=ticket_id,
                run_id=run_id,
                source="orchestrator",
                message=f"{ticket_id} run {run_id} merge needs attention",
                repo_path=repo_path,
                provider_key=run.get("provider_key"),
            )
            self._record_queue_drain_after_event(
                repo_path=repo_path,
                trigger="merge-blocked-dirty-source",
                drive_reviews=False,
            )
            return {"accepted": False, "run": self.runs.get(run_id), "reason": reason}

        merge = _git(
            repo_path,
            "merge",
            "--no-ff",
            branch,
            "-m",
            f"merge {ticket_id} worker run {run_id}",
            check=False,
        )
        if merge.returncode != 0:
            _git(repo_path, "merge", "--abort", check=False)
            reason = (merge.stderr or merge.stdout or "merge failed").strip()
            if artifact_lifecycle is not None:
                try:
                    artifact_lifecycle.record_merge_conflict(
                        run_id=run_id,
                        ticket_id=ticket_id,
                        provider=str(run.get("provider_key") or ""),
                        reason=reason,
                    )
                except Exception as error:  # noqa: BLE001
                    reason += f"; artifact conflict publication failed: {error}"
            self.runs.update(run_id, state="MergeConflict", last_error=reason)
            self._emit_lifecycle(
                "run-failed",
                ticket_id=ticket_id,
                run_id=run_id,
                source="orchestrator",
                message=f"{ticket_id} run {run_id} merge needs attention",
                repo_path=repo_path,
                provider_key=run.get("provider_key"),
            )
            self._record_queue_drain_after_event(
                repo_path=repo_path,
                trigger="merge-conflict",
                drive_reviews=False,
            )
            return {"accepted": False, "run": self.runs.get(run_id), "reason": reason}

        promoted: tuple[str, ...] = ()
        if artifact_lifecycle is not None:
            merged_source_commit = _git_head(repo_path)
            try:
                lifecycle_result = artifact_lifecycle.publish_merge_success(
                    run_id=run_id,
                    ticket_id=ticket_id,
                    provider=str(run.get("provider_key") or ""),
                    merged_source_commit=str(merged_source_commit or ""),
                )
                promoted = lifecycle_result.promoted_ticket_ids
            except Exception as error:  # noqa: BLE001 - source merge is durable; stop honestly.
                reason = f"source merge succeeded but artifact lifecycle publication failed: {error}"
                self.runs.update(run_id, state="MergeConflict", last_error=reason)
                self._emit_lifecycle(
                    "run-failed",
                    ticket_id=ticket_id,
                    run_id=run_id,
                    source="orchestrator",
                    message=f"{ticket_id} source merged but canonical outcome needs recovery",
                    repo_path=repo_path,
                    provider_key=run.get("provider_key"),
                )
                self._record_queue_drain_after_event(
                    repo_path=repo_path,
                    trigger="artifact-publication-failed",
                    drive_reviews=False,
                )
                return {"accepted": False, "run": self.runs.get(run_id), "reason": reason}
            merged_ticket = None
            artifact_lifecycle.cleanup_snapshot(Path(str(run["workspace_path"])))
        else:
            merged_ticket = read_ticket(Path(repo_path) / ".orchestrator" / f"{ticket_id}.md")
            if merged_ticket.get("status") != expected_status:
                reason = (
                    f"merged branch did not publish {ticket_id} as {expected_status}"
                )
                self.runs.update(run_id, state="MergeConflict", last_error=reason)
                self._emit_lifecycle(
                    "run-failed",
                    ticket_id=ticket_id,
                    run_id=run_id,
                    source="orchestrator",
                    message=f"{ticket_id} run {run_id} merge needs attention",
                    repo_path=repo_path,
                    provider_key=run.get("provider_key"),
                )
                self._record_queue_drain_after_event(
                    repo_path=repo_path,
                    trigger="merge-missing-reviewed-ticket-state",
                    drive_reviews=False,
                )
                return {"accepted": False, "run": self.runs.get(run_id), "reason": reason}

        removed, worktree_error = remove_worktree(repo_path, Path(str(run["workspace_path"])))
        delete_branch(repo_path, branch)
        verification_blocked = expected_status == VERIFICATION_BLOCKED_STATUS
        if verification_blocked:
            blocker = str(
                artifact_outcome.verification_blocker
                if artifact_outcome is not None
                else merged_ticket.get("verification_blocker")
                if merged_ticket is not None
                else ""
            ).strip()
            resume = str(
                artifact_outcome.verification_resume
                if artifact_outcome is not None
                else merged_ticket.get("verification_resume")
                if merged_ticket is not None
                else ""
            ).strip()
            self.runs.update(
                run_id,
                state=VERIFICATION_BLOCKED_RUN_STATE,
                last_error=f"verification blocked: {blocker}; resume: {resume}",
            )
        else:
            self.runs.update(run_id, state="Merged")
        self._emit_lifecycle(
            "run-verification-blocked" if verification_blocked else "run-merged",
            ticket_id=ticket_id,
            run_id=run_id,
            source="orchestrator",
            message=(
                f"{ticket_id} is reviewed and waiting on external verification"
                if verification_blocked
                else None
            ),
            repo_path=repo_path,
            provider_key=run.get("provider_key"),
        )
        if not verification_blocked and artifact_lifecycle is None:
            try:
                self._progress_dependents(repo_path=repo_path, finished_ticket_id=ticket_id)
            except Exception as e:  # noqa: BLE001 — merge succeeded; report follow-up safely
                print(f"[orchestrator] dep-progression error after merging {ticket_id}: {e}", file=sys.stderr)
        elif not verification_blocked and artifact_lifecycle is not None:
            for dependent_id in promoted:
                try:
                    self.dispatch(
                        ticket_id=dependent_id,
                        repo_path=repo_path,
                        source="dependency-progression",
                        internally_confirmed_project_id=artifact_lifecycle.store.project_id,
                    )
                except (ValueError, RuntimeError) as error:
                    print(
                        f"[orchestrator] artifact dependent dispatch declined for {dependent_id}: {error}",
                        file=sys.stderr,
                    )
        self._record_queue_drain_after_event(
            repo_path=repo_path,
            trigger="run-merged",
            drive_reviews=True,
        )

        result: dict[str, Any] = {
            "accepted": True,
            "run": self.runs.get(run_id),
            "worktree_removed": removed,
            "promoted": list(promoted),
        }
        if worktree_error:
            result["worktree_error"] = worktree_error
        return result

    def request_worker_retry(
        self,
        run_id: int,
        *,
        reason: str | None = None,
        redispatch: bool = True,
    ) -> dict:
        run = self.runs.get(run_id)
        if not run:
            raise ValueError(f"unknown run_id {run_id}")
        if run.get("state") not in REVIEW_BLOCKING_STATES:
            raise ValueError(f"run {run_id} is not awaiting review")

        repo_path = str(run["repo_path"])
        ticket_id = str(run["ticket_id"])
        workspace_path = Path(str(run["workspace_path"]))
        failure_reason = f"Review requested retry: {(reason or 'work incomplete').strip()}"
        artifact_lifecycle = self._artifact_lifecycle(repo_path)
        if artifact_lifecycle is not None:
            try:
                artifact_lifecycle.record_failure(
                    run_id=run_id,
                    ticket_id=ticket_id,
                    provider=str(run.get("provider_key") or ""),
                    reason=failure_reason,
                    retry=True,
                )
            except Exception as error:  # noqa: BLE001
                raise ValueError(
                    f"could not publish canonical review retry for run {run_id}: {error}"
                ) from error
            artifact_lifecycle.cleanup_snapshot(workspace_path)
        removed, worktree_error = remove_worktree(repo_path, workspace_path)
        delete_branch(repo_path, str(run["branch"]))
        self.runs.update(run_id, state="Failed", last_error=failure_reason)
        self._emit_lifecycle(
            "run-failed",
            ticket_id=ticket_id,
            run_id=run_id,
            source="orchestrator",
            message=f"{ticket_id} run {run_id} needs retry after review",
            repo_path=repo_path,
            provider_key=run.get("provider_key"),
        )

        result: dict[str, Any] = {
            "retry_requested": True,
            "run": self.runs.get(run_id),
            "worktree_removed": removed,
            "redispatched": None,
        }
        if worktree_error:
            result["worktree_error"] = worktree_error
        if redispatch:
            try:
                dispatch_args: dict[str, Any] = {
                    "ticket_id": ticket_id,
                    "repo_path": repo_path,
                    "source": "orchestrator-review-retry",
                }
                if artifact_lifecycle is not None:
                    dispatch_args["internally_confirmed_project_id"] = (
                        artifact_lifecycle.store.project_id
                    )
                result["redispatched"] = self.dispatch(**dispatch_args)
            except (ValueError, RuntimeError) as e:
                result["redispatch_error"] = str(e)
        self._record_queue_drain_after_event(
            repo_path=repo_path,
            trigger="review-retry",
            drive_reviews=False,
        )
        return result

    def resume_verification_blocked(
        self,
        run_id: int,
        *,
        reason: str,
        redispatch: bool = True,
    ) -> dict[str, Any]:
        """Commit an explicit resume transition, then optionally dispatch it.

        A reviewed verification blocker is terminal until a foreground PM or
        human records what changed. This keeps queue-drain reconciliation from
        turning an unchanged environment into recursive worker attempts.
        """
        run = self.runs.get(run_id)
        if not run:
            raise ValueError(f"unknown run_id {run_id}")
        if run.get("state") != VERIFICATION_BLOCKED_RUN_STATE:
            raise ValueError(f"run {run_id} is not verification blocked")

        resume_reason = _clean_required_text(reason, "reason")
        repo = Path(str(run["repo_path"])).expanduser().resolve()
        ticket_id = str(run["ticket_id"])
        artifact_lifecycle = self._artifact_lifecycle(str(repo))
        if artifact_lifecycle is not None:
            try:
                publication = artifact_lifecycle.resume_verification(
                    run_id=run_id,
                    ticket_id=ticket_id,
                    provider=str(run.get("provider_key") or ""),
                    reason=resume_reason,
                )
            except Exception as error:  # noqa: BLE001
                raise ValueError(
                    f"could not publish canonical verification resume for run {run_id}: {error}"
                ) from error
            resume_commit = publication.commit_id
        else:
            ticket_path = repo / ".orchestrator" / f"{ticket_id}.md"
            with self._authoring_mutex():
                _ensure_ticket_authoring_paths_clean(repo, [ticket_path])
                ticket = read_ticket(ticket_path)
                if ticket.get("status") != VERIFICATION_BLOCKED_STATUS:
                    raise ValueError(
                        f"ticket {ticket_id} is {ticket.get('status')!r}, expected "
                        f"{VERIFICATION_BLOCKED_STATUS!r}"
                    )
                if ticket.get("run_id") != run_id:
                    raise ValueError(
                        f"ticket {ticket_id} run_id is {ticket.get('run_id')!r}, expected {run_id}"
                    )

                body = str(ticket.get("body") or "").rstrip()
                resume_entry = f"- **Verification resumed after run {run_id}** — {resume_reason}"
                if "## Run log" in body:
                    ticket["body"] = f"{body}\n{resume_entry}\n"
                else:
                    ticket["body"] = f"{body}\n\n## Run log\n\n{resume_entry}\n"
                ticket["status"] = "ready"
                ticket["run_id"] = None
                raw = ticket.get("_raw_fields")
                for field in VERIFICATION_BLOCKER_FIELDS:
                    ticket.pop(field, None)
                    if isinstance(raw, dict):
                        raw.pop(field, None)
                write_ticket(ticket_path, ticket)
                _commit_ticket_authorship(repo, [ticket_path], [ticket_id])
                resume_commit = _git_head(str(repo))

        self._emit_lifecycle(
            "run-verification-resumed",
            ticket_id=ticket_id,
            run_id=run_id,
            source="orchestrator",
            message=f"{ticket_id} verification resumed: {resume_reason}",
            repo_path=str(repo),
            provider_key=run.get("provider_key"),
        )
        result: dict[str, Any] = {
            "resumed": True,
            "reason": resume_reason,
            "resume_commit": resume_commit,
            "previous_run": self.runs.get(run_id),
            "redispatched": None,
        }
        if redispatch:
            dispatch_args: dict[str, Any] = {
                "ticket_id": ticket_id,
                "repo_path": str(repo),
                "context": f"Verification resumed because: {resume_reason}",
                "source": "verification-resume",
            }
            if artifact_lifecycle is not None:
                dispatch_args["internally_confirmed_project_id"] = (
                    artifact_lifecycle.store.project_id
                )
            result["redispatched"] = self.dispatch(**dispatch_args)
        self._record_queue_drain_after_event(
            repo_path=str(repo),
            trigger="verification-resumed",
            drive_reviews=False,
        )
        return result

    def reconcile_preserved_run(
        self,
        *,
        repo_path: str,
        ticket_id: str,
    ) -> dict[str, Any]:
        """Restore a missing terminal ledger row from a committed ticket.

        This is an explicit recovery action for canonical ticket evidence that
        survived a lost local runs database. It does not mutate the ticket,
        resume work, progress dependencies, or dispatch a worker.
        """
        repo = Path(repo_path).expanduser().resolve()
        canonical_ticket_id = _clean_required_text(ticket_id, "ticket_id")
        if Path(canonical_ticket_id).name != canonical_ticket_id or canonical_ticket_id in {".", ".."}:
            raise ValueError("ticket_id must be a canonical ticket filename stem")
        ticket_path = repo / ".orchestrator" / f"{canonical_ticket_id}.md"
        with self._authoring_mutex():
            _ensure_ticket_authoring_paths_clean(repo, [ticket_path])
            tracked = _git(
                str(repo),
                "cat-file",
                "-e",
                f"HEAD:.orchestrator/{canonical_ticket_id}.md",
                check=False,
            )
            if tracked.returncode != 0:
                raise ValueError(
                    f"ticket {canonical_ticket_id} is not committed at repository HEAD"
                )
            ticket = read_ticket(ticket_path)
            if ticket.get("id") != canonical_ticket_id:
                raise ValueError(
                    f"ticket file id is {ticket.get('id')!r}, expected {canonical_ticket_id!r}"
                )
            status = str(ticket.get("status") or "")
            expected_states = {
                VERIFICATION_BLOCKED_STATUS: VERIFICATION_BLOCKED_RUN_STATE,
                "done": "Merged",
            }
            expected_state = expected_states.get(status)
            if expected_state is None:
                raise ValueError(
                    f"ticket {canonical_ticket_id} is {status!r}; only committed done or "
                    "verification_blocked tickets can restore preserved runs"
                )
            run_id = ticket.get("run_id")
            if not isinstance(run_id, int) or isinstance(run_id, bool) or run_id <= 0:
                raise ValueError(
                    f"ticket {canonical_ticket_id} does not declare a positive run_id"
                )
            body = str(ticket.get("body") or "")
            run_evidence = re.search(
                rf"\bRun\s+{run_id}\b",
                body,
                re.IGNORECASE,
            )
            if "## Run log" not in body or run_evidence is None:
                raise ValueError(
                    f"ticket {canonical_ticket_id} lacks preserved run {run_id} evidence"
                )
            attempt_evidence = re.search(
                rf"\bRun\s+{run_id}\b(?:\*\*)?\s*\(attempt\s+(\d+)\)",
                body,
                re.IGNORECASE,
            )
            preserved_attempt = int(attempt_evidence.group(1)) if attempt_evidence else 1
            if preserved_attempt <= 0:
                raise ValueError(
                    f"ticket {canonical_ticket_id} declares an invalid attempt for run {run_id}"
                )

            existing = self.runs.get(run_id)
            if existing:
                existing_repo = str(Path(str(existing.get("repo_path") or "")).expanduser().resolve())
                if (
                    existing.get("ticket_id") != canonical_ticket_id
                    or existing_repo != str(repo)
                    or existing.get("state") != expected_state
                ):
                    raise ValueError(
                        f"run {run_id} already exists with a different ticket, repo, or state"
                    )
                return {"reconciled": False, "run": existing, "source": "existing-ledger"}

            blocker_error = None
            if status == VERIFICATION_BLOCKED_STATUS:
                blocker = str(ticket.get("verification_blocker") or "").strip()
                resume = str(ticket.get("verification_resume") or "").strip()
                if not blocker or not resume:
                    raise ValueError(
                        f"ticket {canonical_ticket_id} lacks verification blocker metadata"
                    )
                blocker_error = f"verification blocked: {blocker}; resume: {resume}"
            reconciled = self.runs.insert_reconciled(
                run_id=run_id,
                ticket_id=canonical_ticket_id,
                repo_path=str(repo),
                state=expected_state,
                attempt=preserved_attempt,
                last_error=blocker_error,
            )

        self._emit_lifecycle(
            "run-reconciled",
            ticket_id=canonical_ticket_id,
            run_id=run_id,
            source="orchestrator",
            message=f"{canonical_ticket_id} preserved run {run_id} was restored",
            repo_path=str(repo),
            provider_key=reconciled.get("provider_key"),
        )
        return {"reconciled": True, "run": reconciled, "source": "canonical-ticket"}

    def reconcile_orchestrator_command_states(
        self,
        *,
        repo_path: str,
        command_states: list[dict[str, Any]] | None,
    ) -> dict[str, Any]:
        """Reconcile private bridge/app journal outcomes into daemon recovery state."""
        repo = str(Path(repo_path).expanduser().resolve())
        reconciled: list[dict[str, Any]] = []
        ignored: list[str] = []
        protected_terminal_statuses = (
            ORCHESTRATOR_COMMAND_TERMINAL_STATUSES
            - {"delivery_failed", "superseded", "clarification_required"}
        )
        for raw in (command_states or [])[-200:]:
            if not isinstance(raw, dict):
                continue
            command_id = str(raw.get("relay_command_id") or "").strip()
            intent_id = str(raw.get("intent_id") or "").strip() or None
            state = str(raw.get("state") or raw.get("status") or "").strip().lower()
            try:
                command_seq = int(raw.get("relay_command_seq"))
            except (TypeError, ValueError):
                continue
            if not command_id or state not in {"claimed", "delivery_failed", "superseded"}:
                continue
            event_repo = str(Path(str(raw.get("repo_path") or repo)).expanduser().resolve())
            if event_repo != repo:
                ignored.append(command_id)
                continue

            existing = self.orchestrator_commands.get_private(command_id, intent_id=intent_id)
            if existing is None:
                if state != "delivery_failed":
                    ignored.append(command_id)
                    continue
                source_text = str(raw.get("source_text") or "").strip()
                if not source_text:
                    source_text = "Relay command delivery failed before provider readiness."
                self.orchestrator_commands.record(
                    repo_path=repo,
                    source_text=source_text,
                    relay_command_seq=command_seq,
                    relay_command_id=command_id,
                    intent_id=intent_id,
                    within_turn_order=raw.get("within_turn_order"),
                    provider_key=raw.get("provider"),
                    action=raw.get("action"),
                    outcome="delivery-failed",
                    target=raw.get("target"),
                    disposition=raw.get("disposition"),
                    cancellation_scope=raw.get("cancellation_scope"),
                    lifecycle_state=raw.get("lifecycle_state"),
                    received_at=raw.get("received_at"),
                    status="delivery_failed",
                )
                updated = self.orchestrator_commands.update_status(
                    command_id,
                    intent_id=intent_id,
                    status="delivery_failed",
                    outcome="delivery-failed",
                    status_message="Delivery failed before the embedded provider confirmed a ticket action.",
                )
                if updated:
                    reconciled.append(updated)
                continue

            existing_status = str(existing.get("status") or "")
            if existing_status in protected_terminal_statuses:
                ignored.append(command_id)
                continue
            if state == "claimed" and existing_status not in {
                "received",
                "classified",
                "queued",
                "planning",
            }:
                ignored.append(command_id)
                continue
            if state == "delivery_failed" and existing_status == "superseded":
                ignored.append(command_id)
                continue

            if state == "delivery_failed":
                outcome = "delivery-failed"
                message = "Delivery failed before the embedded provider confirmed a ticket action."
            elif state == "superseded":
                outcome = "superseded"
                message = "The command was superseded locally and will not be recovered or replayed."
            else:
                outcome = "provider-claimed"
                message = "The embedded provider claimed the command before the previous session ended."
            updated = self.orchestrator_commands.update_status(
                command_id,
                intent_id=intent_id,
                status=state,
                outcome=outcome,
                status_message=message,
            )
            if updated:
                reconciled.append(updated)
        return {"reconciled": reconciled, "ignored": ignored}

    def ensure_orchestrator_session(
        self,
        *,
        repo_path: str,
        provider: str | None = None,
        model: str | None = None,
        effort: str | None = None,
        source: str | None = None,
        pid: int | None = None,
        state: str = "idle",
        command_action_states: list[dict[str, Any]] | None = None,
    ) -> dict:
        if not repo_path:
            raise ValueError("repo_path is required")
        repo = Path(repo_path).expanduser().resolve()
        if not repo.is_dir():
            raise ValueError(f"repo_path {repo} is not a directory")
        general = self.cfg.get("general", {})
        provider_key = provider or general.get("provider") or self.agent_kind
        result = self.orchestrator_sessions.ensure(
            repo_path=str(repo),
            provider_key=str(provider_key),
            model_alias=model or general.get("model"),
            effort=effort or general.get("orchestrator_effort"),
            source=source or "direct",
            pid=pid,
            state=state,
        )
        reconciliation = self.reconcile_orchestrator_command_states(
            repo_path=str(repo),
            command_states=command_action_states,
        )
        try:
            self.process_orchestrator_commands(repo_path=str(repo), limit=10)
        except Exception as e:  # noqa: BLE001 - activation must still succeed.
            print(f"[orchestrator] command resume failed for {repo}: {e}", file=sys.stderr)
        return {
            "orchestrator_session": result,
            "command_action_reconciliation": reconciliation,
            "recoverable_commands": self.orchestrator_commands.recoverable(
                repo_path=str(repo),
                limit=10,
            ),
        }

    def heartbeat_orchestrator_session(
        self,
        *,
        session_id: int | None = None,
        repo_path: str | None = None,
        provider: str | None = None,
        state: str | None = None,
    ) -> dict:
        result = self.orchestrator_sessions.heartbeat(
            session_id=session_id,
            repo_path=repo_path,
            provider_key=provider,
            state=state,
        )
        if result is None:
            raise ValueError("orchestrator session not found")
        return {"orchestrator_session": result}

    def stop_orchestrator_session(
        self,
        *,
        session_id: int | None = None,
        repo_path: str | None = None,
        reason: str | None = None,
    ) -> dict:
        result = self.orchestrator_sessions.stop(
            session_id=session_id,
            repo_path=repo_path,
            reason=reason,
        )
        if result is None:
            raise ValueError("orchestrator session not found")
        return {"orchestrator_session": result}

    def record_orchestrator_command(
        self,
        *,
        repo_path: str,
        source_text: str,
        relay_command_seq: int | str,
        relay_command_id: str,
        intent_id: str | None = None,
        within_turn_order: int | str | None = None,
        session_id: int | None = None,
        provider: str | None = None,
        context: str | None = None,
        action: str | None = None,
        outcome: str | None = None,
        target: str | None = None,
        disposition: str | None = None,
        cancellation_scope: str | None = None,
        lifecycle_state: str | None = None,
        received_at: float | None = None,
        status: str = "received",
        defer_processing: bool = False,
    ) -> dict:
        if not repo_path:
            raise ValueError("repo_path is required")
        _validate_relay_command(
            relay_command_seq,
            relay_command_id,
            relay_intent_id=intent_id,
            mutation=_relay_mutation_metadata(
                "orchestrator_command",
                request_id=str(intent_id or relay_command_id),
            ),
        )
        requested_status = str(status or "received").strip().lower()
        repo = Path(repo_path).expanduser().resolve()
        work_action = str(action or "").strip().lower() in {
            "create_ticket",
            "update_ticket",
            "dispatch_ticket",
        }
        status_message = None
        has_child_repos = False
        if repo.is_dir():
            try:
                has_child_repos = any(
                    child.is_dir() and (child / ".git").exists()
                    for child in repo.iterdir()
                )
            except OSError:
                has_child_repos = False
        concrete_project = (repo / ".git").exists() and not has_child_repos
        if defer_processing and work_action and not concrete_project:
            requested_status = "clarification_required"
            outcome = "waiting-for-project-choice"
            status_message = (
                "Waiting for a target project; the active route is a workspace root, "
                "so no parent ticket was created."
            )
        elif defer_processing and requested_status in {"received", "classified"}:
            requested_status = "queued"

        result = self.orchestrator_commands.record(
            repo_path=repo_path,
            source_text=source_text,
            relay_command_seq=relay_command_seq,
            relay_command_id=relay_command_id,
            intent_id=intent_id,
            within_turn_order=within_turn_order,
            session_id=session_id,
            provider_key=provider,
            context=context,
            action=action,
            outcome=outcome,
            target=target,
            disposition=disposition,
            cancellation_scope=cancellation_scope,
            lifecycle_state=lifecycle_state,
            received_at=received_at,
            status=requested_status,
        )
        if status_message:
            result = self.orchestrator_commands.update_status(
                str(relay_command_id),
                intent_id=intent_id,
                status=requested_status,
                outcome=outcome,
                status_message=status_message,
            ) or result
        if defer_processing:
            return {
                "orchestrator_command": result,
                "processing": {"processed": []},
            }
        processing = self.process_orchestrator_commands(repo_path=repo_path, limit=10)
        latest = self.orchestrator_commands.get_public(
            str(relay_command_id or ""),
            intent_id=intent_id,
        ) or result
        return {"orchestrator_command": latest, "processing": processing}

    def process_orchestrator_commands(
        self,
        *,
        repo_path: str | None = None,
        limit: int = 20,
    ) -> dict[str, Any]:
        commands = self.orchestrator_commands.pending(repo_path=repo_path, limit=limit)
        processed: list[dict[str, Any]] = []
        for command in commands:
            processed.append(self._process_orchestrator_command(command))
        return {"processed": processed}

    def _process_orchestrator_command(self, command: dict[str, Any]) -> dict[str, Any]:
        command_id = str(command.get("relay_command_id") or "")
        intent_id = str(command.get("intent_id") or command_id)
        if not command_id:
            return {"status": "failed", "error": "missing relay_command_id"}
        repo_path = str(command.get("repo_path") or "")
        relay_command_seq = command.get("relay_command_seq")
        relay_command_id = command.get("relay_command_id")
        relay_metadata = {
            "relay_command_seq": relay_command_seq,
            "relay_command_id": relay_command_id,
            "intent_id": intent_id,
            "within_turn_order": command.get("within_turn_order"),
        }
        if command.get("provider_key"):
            relay_metadata["provider"] = command.get("provider_key")

        if not _relay_command_current(
            relay_command_seq,
            str(relay_command_id or ""),
        ) and not authorization_exists(
            RELAY_COMMAND_AUTHORIZATION_FILE,
            relay_command_seq,
            relay_command_id,
        ):
            message = "Skipped stale Relay command because a newer command superseded it."
            updated = self.orchestrator_commands.update_status(
                command_id,
                intent_id=intent_id,
                status="stale",
                outcome="stale-command",
                status_message=message,
            )
            return updated or {"relay_command_id": command_id, "status": "stale"}

        self.orchestrator_commands.update_status(
            command_id,
            intent_id=intent_id,
            status="planning",
        )
        self._heartbeat_command_session(command, state="planning")

        try:
            action = resolve_command_action(
                str(command.get("source_text") or ""),
                repo_path=repo_path,
                relay_command=relay_metadata,
            )
            if action.kind == "create_ticket":
                result = self._author_ticket_for_command(command, relay_metadata)
                self._heartbeat_command_session(command, state="idle")
                return result
            if action.kind == "dispatch_ticket" and action.ticket_id:
                result = self.dispatch(
                    ticket_id=action.ticket_id,
                    repo_path=repo_path,
                    source="orchestrator-command",
                    relay_command_seq=relay_command_seq,
                    relay_command_id=str(relay_command_id or ""),
                    relay_intent_id=intent_id,
                )
                run = result.get("run") or {}
                message = (
                    f"Dispatching {action.ticket_id}."
                    if not result.get("already_active")
                    else f"{action.ticket_id} already has an active or review-pending run."
                )
                updated = self.orchestrator_commands.update_status(
                    command_id,
                    intent_id=intent_id,
                    status="authored",
                    action=action.kind,
                    outcome="dispatch-started",
                    ticket_id=action.ticket_id,
                    status_message=message,
                )
                self._heartbeat_command_session(command, state="awaiting_workers")
                self._notify_command_outcome(
                    command,
                    message=message,
                    ticket_id=action.ticket_id,
                    run_id=run.get("id"),
                )
                return updated or {"relay_command_id": command_id, "status": "authored"}
            if action.kind in {"update_ticket", "inspect_ticket"} and action.ticket_id:
                message = (
                    f"Clarification needed before changing {action.ticket_id}; "
                    "the backstage loop will not guess at ticket edits from raw command text."
                )
                updated = self.orchestrator_commands.update_status(
                    command_id,
                    intent_id=intent_id,
                    status="blocked",
                    action=action.kind,
                    outcome="clarification-needed",
                    ticket_id=action.ticket_id,
                    status_message=message,
                )
                self._heartbeat_command_session(command, state="blocked")
                self._notify_command_outcome(command, message=message, ticket_id=action.ticket_id)
                return updated or {"relay_command_id": command_id, "status": "blocked"}

            if action.kind in {"conversation", "control", "inline_work"}:
                message = "No backstage ticket action is needed for this Relay command."
                updated = self.orchestrator_commands.update_status(
                    command_id,
                    intent_id=intent_id,
                    status="handled",
                    action=action.kind,
                    outcome="non-work-command",
                    status_message=message,
                )
                self._heartbeat_command_session(command, state="idle")
                return updated or {"relay_command_id": command_id, "status": "handled"}

            message = "Clarification needed before creating or dispatching a ticket."
            updated = self.orchestrator_commands.update_status(
                command_id,
                intent_id=intent_id,
                status="blocked",
                action=action.kind,
                outcome="clarification-needed",
                status_message=message,
            )
            self._heartbeat_command_session(command, state="blocked")
            self._notify_command_outcome(command, message=message)
            return updated or {"relay_command_id": command_id, "status": "blocked"}
        except ValueError as e:
            status = "stale" if "stale Relay command" in str(e) else "blocked"
            outcome = "stale-command" if status == "stale" else "blocked"
            message = str(e) if status == "stale" else "Blocked while authoring a ticket."
            updated = self.orchestrator_commands.update_status(
                command_id,
                intent_id=intent_id,
                status=status,
                outcome=outcome,
                status_message=message,
                error=str(e),
            )
            if status != "stale":
                self._heartbeat_command_session(command, state="blocked")
                self._notify_command_outcome(command, message=message)
            return updated or {"relay_command_id": command_id, "status": status, "error": str(e)}
        except Exception as e:  # noqa: BLE001 - keep the daemon loop alive.
            message = "Failed while authoring a ticket."
            updated = self.orchestrator_commands.update_status(
                command_id,
                intent_id=intent_id,
                status="failed",
                outcome="failed",
                status_message=message,
                error=str(e),
            )
            self._heartbeat_command_session(command, state="failed")
            self._notify_command_outcome(command, message=message)
            print(f"[orchestrator] command {command_id} failed: {e}", file=sys.stderr)
            return updated or {"relay_command_id": command_id, "status": "failed", "error": str(e)}

    def _author_ticket_for_command(self, command: dict[str, Any], relay_metadata: dict[str, Any]) -> dict[str, Any]:
        command_id = str(command.get("relay_command_id") or "")
        intent_id = str(command.get("intent_id") or command_id)
        repo = Path(str(command.get("repo_path") or "")).expanduser().resolve()
        if not repo.is_dir() or not (repo / ".git").exists():
            raise ValueError(f"repo_path {repo} is not a git repository")
        if not (repo / ".orchestrator" / "config.toml").is_file():
            raise ValueError(f"repo_path {repo} has no .orchestrator/config.toml")

        actions = [_autonomous_ticket_action(
            str(command.get("source_text") or ""),
            self.cfg.get("general", {}),
            refined_context=str(command.get("context") or ""),
        )]
        result = self.apply_orchestrator_actions(
            repo_path=str(repo),
            actions=actions,
            request_id=f"relay-command:{intent_id}",
            relay_command_seq=relay_metadata.get("relay_command_seq"),
            relay_command_id=str(relay_metadata.get("relay_command_id") or ""),
            relay_intent_id=intent_id,
        )
        ticket_id = None
        if result.get("tickets_written"):
            ticket_id = result["tickets_written"][0].get("ticket_id")
        message = f"Created ticket {ticket_id}." if ticket_id else "Created a refined ticket."
        updated = self.orchestrator_commands.update_status(
            command_id,
            intent_id=intent_id,
            status="authored",
            action="create_ticket",
            outcome="ticket-created",
            ticket_id=ticket_id,
            status_message=message,
        )
        self._notify_command_outcome(command, message=message, ticket_id=ticket_id)
        return updated or {"relay_command_id": command_id, "status": "authored", "ticket_id": ticket_id}

    def _heartbeat_command_session(self, command: dict[str, Any], *, state: str) -> None:
        session_id = command.get("session_id")
        repo_path = command.get("repo_path")
        provider = command.get("provider_key")
        try:
            self.orchestrator_sessions.heartbeat(
                session_id=int(session_id) if session_id is not None else None,
                repo_path=str(repo_path) if repo_path else None,
                provider_key=str(provider) if provider else None,
                state=state,
            )
        except (TypeError, ValueError):
            pass

    def _notify_command_outcome(
        self,
        command: dict[str, Any],
        *,
        message: str,
        ticket_id: str | None = None,
        run_id: int | None = None,
    ) -> None:
        try:
            metadata = RelayCommandMetadata.from_dict({
                "relay_command_seq": command.get("relay_command_seq"),
                "relay_command_id": command.get("relay_command_id"),
                "provider": command.get("provider_key"),
            })
            event = PMStatusEvent(
                phase="outcome",
                message=message,
                source="orchestrator",
                command=metadata,
                ticket_id=ticket_id,
                run_id=run_id,
            )
        except ValueError as e:
            print(f"[orchestrator] could not build command status event: {e}", file=sys.stderr)
            return
        _notify_state(
            "working",
            text=event.message,
            status_event=event.to_dict(),
        )

    def list_orchestrator_sessions(
        self,
        *,
        repo_path: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        return self.orchestrator_sessions.list(repo_path=repo_path, limit=limit)

    def pending_messenger_outcomes(
        self,
        *,
        repo_path: str | None = None,
        provider: str | None = None,
        limit: int = 20,
    ) -> list[dict[str, Any]]:
        return self.messenger_outcomes.pending(
            repo_path=repo_path,
            provider_key=provider,
            limit=limit,
        )

    def mark_messenger_outcome_delivered(self, outcome_id: int) -> dict[str, Any] | None:
        return self.messenger_outcomes.mark_delivered(outcome_id)

    def record_messenger_outcome_attempt(self, outcome_id: int) -> None:
        self.messenger_outcomes.record_attempt(outcome_id)

    def _authoring_mutex(self) -> threading.Lock:
        lock = getattr(self, "_ticket_authoring_lock", None)
        if lock is None:
            lock = threading.Lock()
            self._ticket_authoring_lock = lock
        return lock

    def _action_request_ids(self) -> set[str]:
        seen = getattr(self, "_orchestrator_action_request_ids", None)
        if seen is None:
            seen = set()
            self._orchestrator_action_request_ids = seen
        return seen

    def _completed_spike(self, repo_path: str, ticket_id: str, run_id: int) -> tuple[Path, dict[str, Any]]:
        repo = Path(repo_path).expanduser().resolve()
        if not repo.is_dir() or not (repo / ".git").exists():
            raise ValueError(f"origin_repo_path {repo} is not a git repository")
        ticket_path = repo / ".orchestrator" / f"{ticket_id.upper()}.md"
        if not ticket_path.is_file():
            raise ValueError(f"originating spike {ticket_id.upper()} not found")
        ticket = read_ticket(ticket_path)
        if ticket.get("execution_mode") != SPIKE_EXECUTION_MODE:
            raise ValueError(f"originating ticket {ticket_id.upper()} is not a spike")
        if ticket.get("status") != "done":
            raise ValueError(f"originating spike {ticket_id.upper()} is not complete")
        if ticket.get("run_id") != run_id:
            raise ValueError(
                f"originating spike run changed: expected {run_id}, found {ticket.get('run_id')}"
            )
        if not _body_section(ticket, "Spike report"):
            raise ValueError(f"originating spike {ticket_id.upper()} has no durable Spike report")
        return repo, ticket

    def _followup_target_repo(self, origin_repo: Path, value: str) -> Path:
        target = Path(value).expanduser().resolve()
        registered = {Path(path).resolve() for path in _registered_project_repo_paths(self.program_registry_path)}
        if target != origin_repo and target not in registered:
            raise ValueError(
                "ambiguous project ownership: select one registered target project before accepting"
            )
        if not target.is_dir() or not (target / ".git").exists():
            raise ValueError(f"target project {target} is not a git repository")
        if not (target / ".orchestrator" / "config.toml").is_file():
            raise ValueError(f"target project {target} has no canonical board config")
        return target

    def propose_spike_followups(
        self,
        *,
        origin_repo_path: str,
        origin_ticket_id: str,
        origin_run_id: int,
        proposals: list[dict[str, Any]] | None = None,
        provider: str | None = None,
    ) -> dict[str, Any]:
        origin_repo, spike = self._completed_spike(
            origin_repo_path, origin_ticket_id, int(origin_run_id)
        )
        raw_drafts = proposals
        if raw_drafts is None:
            raw_drafts = automatic_followup_drafts(
                spike.get("body") or "", origin_repo_path=str(origin_repo)
            )
        if not isinstance(raw_drafts, list) or not raw_drafts:
            raise ValueError(
                "the completed spike has no actionable recommended next steps; provide refined proposals"
            )
        drafts: list[dict[str, Any]] = []
        for raw in raw_drafts:
            draft = sanitize_followup_draft(raw, origin_repo_path=str(origin_repo))
            self._followup_target_repo(origin_repo, draft["target_repo_path"])
            drafts.append(draft)
        batch, created = self.followup_proposals.create_or_get(
            origin_repo_path=str(origin_repo),
            origin_ticket_id=origin_ticket_id.upper(),
            origin_run_id=int(origin_run_id),
            provider_key=_clean_optional_text(provider),
            drafts=drafts,
        )
        return {"batch": batch, "created": created, "duplicate": not created}

    def review_spike_followup(
        self,
        *,
        batch_id: str,
        proposal_id: str,
        decision: str,
        updates: dict[str, Any] | None = None,
        relay_command_seq: int | str | None = None,
        relay_command_id: str | None = None,
        relay_intent_id: str | None = None,
    ) -> dict[str, Any]:
        with self._authoring_mutex():
            return self._review_spike_followup_locked(
                batch_id=batch_id,
                proposal_id=proposal_id,
                decision=decision,
                updates=updates,
                relay_command_seq=relay_command_seq,
                relay_command_id=relay_command_id,
                relay_intent_id=relay_intent_id,
            )

    def _review_spike_followup_locked(
        self,
        *,
        batch_id: str,
        proposal_id: str,
        decision: str,
        updates: dict[str, Any] | None = None,
        relay_command_seq: int | str | None = None,
        relay_command_id: str | None = None,
        relay_intent_id: str | None = None,
    ) -> dict[str, Any]:
        batch = self.followup_proposals.get(batch_id)
        if batch is None:
            raise ValueError(f"follow-up batch {batch_id} not found")
        proposal = next(
            (item for item in batch["proposals"] if item["id"] == proposal_id), None
        )
        if proposal is None:
            raise ValueError(f"follow-up proposal {proposal_id} not found")
        if proposal["state"] != "draft":
            return {"batch": batch, "duplicate": True}

        origin_repo, _ = self._completed_spike(
            batch["origin_repo_path"], batch["origin_ticket_id"], batch["origin_run_id"]
        )
        draft = proposal["draft"]
        if updates is not None:
            if not isinstance(updates, dict):
                raise ValueError("updates must be an object")
            draft = sanitize_followup_draft(
                {**draft, **updates}, origin_repo_path=str(origin_repo)
            )
            self._followup_target_repo(origin_repo, draft["target_repo_path"])
            batch = self.followup_proposals.update_draft(batch_id, proposal_id, draft)

        normalized_decision = str(decision or "").strip().lower()
        if normalized_decision == "edit":
            if updates is None:
                raise ValueError("edit requires updates")
            return {"batch": batch, "edited": proposal_id}
        if normalized_decision == "reject":
            return {
                "batch": self.followup_proposals.set_result(
                    batch_id, proposal_id, state="rejected"
                ),
                "rejected": proposal_id,
            }
        if normalized_decision != "accept":
            raise ValueError("decision must be 'edit', 'accept', or 'reject'")

        _validate_relay_command(
            relay_command_seq,
            relay_command_id,
            relay_intent_id=relay_intent_id,
            mutation=_relay_mutation_metadata(
                "spike_followup_accept",
                request_id=f"{batch_id}:{proposal_id}",
            ),
        )

        try:
            ticket_id, duplicate = self._accept_spike_followup(
                batch=batch, proposal_id=proposal_id, draft=draft
            )
        except (ValueError, RuntimeError) as error:
            failed = self.followup_proposals.set_error(batch_id, proposal_id, str(error))
            return {
                "batch": failed,
                "partial": True,
                "committed": [],
                "not_committed": [{"proposal_id": proposal_id, "error": str(error)}],
            }
        accepted = self.followup_proposals.set_result(
            batch_id, proposal_id, state="accepted", ticket_id=ticket_id
        )
        return {
            "batch": accepted,
            "committed": [{"proposal_id": proposal_id, "ticket_id": ticket_id}],
            "not_committed": [],
            "duplicate": duplicate,
        }

    def _accept_spike_followup(
        self,
        *,
        batch: dict[str, Any],
        proposal_id: str,
        draft: dict[str, Any],
    ) -> tuple[str, bool]:
        origin_repo, _ = self._completed_spike(
            batch["origin_repo_path"], batch["origin_ticket_id"], batch["origin_run_id"]
        )
        target = self._followup_target_repo(origin_repo, draft["target_repo_path"])
        key = followup_acceptance_key(batch["id"], proposal_id)
        marker = f"{FOLLOWUP_KEY_PREFIX} {key}"
        for ticket in scan_repo(target):
            if marker in str(ticket.get("body") or ""):
                return str(ticket["id"]), True

        for dependency in draft["depends_on"]:
            if not (target / ".orchestrator" / f"{dependency}.md").is_file():
                raise ValueError(
                    f"dependency {dependency} is not present on target board {target}"
                )

        current_branch = _git_text(str(target), "branch", "--show-current")
        if not current_branch:
            raise ValueError("target project must be on a named canonical branch")
        target_head = _git_text(str(target), "rev-parse", "HEAD")
        origin_ticket_path = origin_repo / ".orchestrator" / f"{batch['origin_ticket_id']}.md"
        if target == origin_repo:
            origin_commit = _git_text(
                str(origin_repo), "log", "-1", "--format=%H", "--", str(origin_ticket_path)
            )
            ancestry = _git(
                str(target), "merge-base", "--is-ancestor", origin_commit, target_head, check=False
            )
            if not origin_commit or ancestry.returncode != 0:
                raise ValueError(
                    "originating spike result is not an ancestor of the target board branch"
                )

        orch_dir = target / ".orchestrator"
        config_path = orch_dir / "config.toml"
        prefix, next_id, config_text = _ticket_config(config_path)
        ticket_number = next_id
        while (orch_dir / f"{prefix}-{ticket_number}.md").exists():
            ticket_number += 1
        ticket_id = f"{prefix}-{ticket_number}"
        ticket_path = orch_dir / f"{ticket_id}.md"
        _ensure_ticket_authoring_paths_clean(target, [config_path, ticket_path])
        staged = _git(str(target), "diff", "--cached", "--name-only", check=False)
        if staged.returncode != 0 or staged.stdout.strip():
            raise ValueError("follow-up authoring blocked by already-staged changes")
        if _git_text(str(target), "rev-parse", "HEAD") != target_head:
            raise ValueError("target branch changed while preparing the follow-up ticket")

        order = ticket_number
        provenance = (
            "## Provenance\n\n"
            f"- Originating spike: `{batch['origin_ticket_id']}`\n"
            f"- Spike run: {batch['origin_run_id']}\n\n"
            f"<!-- {marker} -->"
        )
        ticket = {
            "id": ticket_id,
            "title": draft["title"],
            "status": "backlog",
            "priority": draft["priority"],
            "execution_mode": "implementation",
            "depends_on": draft["depends_on"],
            "run_id": None,
            "canceled": False,
            "order": order,
            "body": _structured_ticket_body(
                draft["description"], draft["acceptance_criteria"]
            ).rstrip() + "\n\n" + provenance + "\n",
            "_raw_fields": {
                "worker_model": draft["worker_model"],
                "worker_effort": draft["worker_effort"],
                "worker_sizing_rationale": draft["worker_sizing_rationale"],
                "worker_provider_notes": draft["worker_provider_notes"],
            },
        }
        try:
            _write_ticket_config_next_id(config_path, config_text, ticket_number + 1)
            write_ticket(ticket_path, ticket)
            paths = _ticket_authoring_pathspecs(target, [config_path, ticket_path])
            added = _git(str(target), "add", "--", *paths, check=False)
            if added.returncode != 0:
                raise RuntimeError((added.stderr or added.stdout).strip())
            commit = _git(
                str(target), "commit", "-m",
                f"chore: author {ticket_id} from {batch['origin_ticket_id']} spike",
                "--", *paths, check=False,
            )
            if commit.returncode != 0:
                raise RuntimeError((commit.stderr or commit.stdout).strip())
        except Exception as error:
            _git(
                str(target), "restore", "--staged", "--",
                str(config_path.relative_to(target)), str(ticket_path.relative_to(target)),
                check=False,
            )
            config_path.write_text(config_text)
            if ticket_path.exists():
                ticket_path.unlink()
            raise RuntimeError(f"follow-up ticket commit failed: {error}") from error
        _notify_orchestration_trace("ticket-created", ticket_id=ticket_id)
        return ticket_id, False

    def apply_orchestrator_actions(
        self,
        *,
        repo_path: str,
        actions: list[dict[str, Any]],
        request_id: str | None = None,
        relay_command_seq: int | str | None = None,
        relay_command_id: str | None = None,
        relay_intent_id: str | None = None,
    ) -> dict:
        if not repo_path:
            raise ValueError("repo_path is required")
        if not isinstance(actions, list) or not actions:
            raise ValueError("actions must be a non-empty list")

        repo = Path(repo_path).expanduser().resolve()
        orch_dir = repo / ".orchestrator"
        if not repo.is_dir() or not (repo / ".git").exists():
            raise ValueError(f"repo_path {repo} is not a git repository")
        if not orch_dir.is_dir():
            raise ValueError(f"repo_path {repo} has no .orchestrator directory")

        action_request_id = _clean_optional_text(request_id)
        with self._authoring_mutex():
            seen_request_ids = self._action_request_ids()
            if action_request_id and action_request_id in seen_request_ids:
                raise ValueError(f"duplicate orchestrator action request: {action_request_id}")

            tickets_written: list[dict[str, Any]] = []
            authored_paths: list[Path] = []
            authored_ticket_ids: list[str] = []
            dispatch_requests: list[dict[str, Any]] = []
            dispatches: list[dict[str, Any]] = []
            skipped: list[dict[str, Any]] = []
            canceled: list[dict[str, Any]] = []
            command_id = str(relay_command_id or "").strip()
            command_intent_id = (
                action_request_id[len("relay-command:"):]
                if action_request_id and action_request_id.startswith("relay-command:")
                else None
            )
            command_store = getattr(self, "orchestrator_commands", None)
            if command_id and command_store and command_store.get_private(
                command_id,
                intent_id=command_intent_id,
            ):
                command_store.update_status(
                    command_id,
                    intent_id=command_intent_id,
                    status="mutation_authorized",
                    outcome="mutation-authorized",
                )

            def _started_anything() -> bool:
                return bool(tickets_written or dispatches or skipped)

            def _public_dispatch_requests() -> list[dict[str, Any]]:
                return [
                    {
                        key: value
                        for key, value in request.items()
                        if not str(key).startswith("_")
                    }
                    for request in dispatch_requests
                ]

            def _validate_mutation(mutation: dict[str, Any]) -> None:
                _validate_relay_command(
                    relay_command_seq,
                    relay_command_id,
                    relay_intent_id=relay_intent_id or command_intent_id,
                    mutation=mutation,
                )

            def _cancel_and_return(
                mutations: list[dict[str, Any]],
                reason: str,
            ) -> dict[str, Any]:
                canceled.extend(_relay_canceled_entry(mutation, reason) for mutation in mutations)
                mark_mutations_canceled(
                    RELAY_COMMAND_AUTHORIZATION_FILE,
                    relay_command_seq,
                    relay_command_id,
                    mutations,
                    reason=reason,
                )
                if action_request_id:
                    seen_request_ids.add(action_request_id)
                if command_id and command_store and command_store.get_private(
                    command_id,
                    intent_id=command_intent_id,
                ):
                    command_store.update_status(
                        command_id,
                        intent_id=command_intent_id,
                        status="superseded",
                        outcome="superseded",
                        status_message="The authorized action was superseded before all mutations completed.",
                    )
                return {
                    "repo_path": str(repo),
                    "request_id": action_request_id,
                    "tickets_written": tickets_written,
                    "dispatch_requests": _public_dispatch_requests(),
                    "dispatches": dispatches,
                    "skipped": skipped,
                    "canceled": canceled,
                    "partial": True,
                    "superseded": True,
                    "status_message": reason,
                }

            for action_index, raw_action in enumerate(actions):
                if not isinstance(raw_action, dict):
                    raise ValueError("each action must be an object")
                kind = str(raw_action.get("kind") or "").strip().lower()
                if kind not in ORCHESTRATOR_ACTION_KINDS:
                    raise ValueError(f"invalid orchestrator action kind: {kind!r}")

                if kind == "create_ticket":
                    mutation = _orchestrator_action_mutation(
                        raw_action,
                        action_index=action_index,
                        request_id=action_request_id,
                    )
                    try:
                        _validate_mutation(mutation)
                    except ValueError as e:
                        if not _started_anything():
                            raise
                        remaining = [
                            _orchestrator_action_mutation(
                                action,
                                action_index=index,
                                request_id=action_request_id,
                            )
                            for index, action in enumerate(actions[action_index:], start=action_index)
                            if isinstance(action, dict)
                        ]
                        return _cancel_and_return(remaining, str(e))
                    config_path = orch_dir / "config.toml"
                    if config_path not in authored_paths:
                        _ensure_ticket_authoring_paths_clean(repo, [config_path])
                    ticket_id = self._create_orchestrator_ticket(repo, raw_action)
                    tickets_written.append({"ticket_id": ticket_id, "action": kind})
                    authored_paths.extend([config_path, orch_dir / f"{ticket_id}.md"])
                    authored_ticket_ids.append(ticket_id)
                elif kind in {"edit_ticket", "update_dependencies"}:
                    mutation = _orchestrator_action_mutation(
                        raw_action,
                        action_index=action_index,
                        request_id=action_request_id,
                    )
                    try:
                        _validate_mutation(mutation)
                    except ValueError as e:
                        if not _started_anything():
                            raise
                        remaining = [
                            _orchestrator_action_mutation(
                                action,
                                action_index=index,
                                request_id=action_request_id,
                            )
                            for index, action in enumerate(actions[action_index:], start=action_index)
                            if isinstance(action, dict)
                        ]
                        return _cancel_and_return(remaining, str(e))
                    ticket_id = _clean_required_text(raw_action.get("ticket_id"), "ticket_id").upper()
                    ticket_path = orch_dir / f"{ticket_id}.md"
                    if ticket_path not in authored_paths:
                        _ensure_ticket_authoring_paths_clean(repo, [ticket_path])
                    ticket_id = self._edit_orchestrator_ticket(repo, raw_action, dependencies_only=(kind == "update_dependencies"))
                    tickets_written.append({"ticket_id": ticket_id, "action": kind})
                    authored_paths.append(ticket_path)
                    authored_ticket_ids.append(ticket_id)
                elif kind == "request_worker":
                    request = self._worker_creation_request(repo, raw_action)
                    request["_relay_action_index"] = action_index
                    dispatch_requests.append(request)

            if authored_paths:
                _commit_ticket_authorship(repo, authored_paths, authored_ticket_ids)

            all_tickets = scan_repo(repo)
            for request_index, request in enumerate(dispatch_requests):
                ticket_id = request["ticket_id"]
                mutation = _relay_mutation_metadata(
                    "orchestrator_action",
                    ticket_id=ticket_id,
                    action_kind="request_worker",
                    action_index=request.get("_relay_action_index"),
                    request_id=action_request_id,
                )
                try:
                    _validate_mutation(mutation)
                except ValueError as e:
                    if not _started_anything():
                        raise
                    remaining = [
                        _relay_mutation_metadata(
                            "orchestrator_action",
                            ticket_id=remaining_request["ticket_id"],
                            action_kind="request_worker",
                            action_index=remaining_request.get("_relay_action_index"),
                            request_id=action_request_id,
                        )
                        for remaining_request in dispatch_requests[request_index:]
                    ]
                    return _cancel_and_return(remaining, str(e))
                ticket_path = orch_dir / f"{ticket_id}.md"
                ticket = read_ticket(ticket_path)
                if ticket["canceled"]:
                    skipped.append({"ticket_id": ticket_id, "reason": "canceled"})
                    continue
                if ticket.get("draft"):
                    skipped.append({"ticket_id": ticket_id, "reason": "draft"})
                    continue
                if ticket["status"] not in ("backlog", "ready"):
                    skipped.append({"ticket_id": ticket_id, "reason": f"status:{ticket['status']}"})
                    continue
                if ticket["status"] == "backlog":
                    ticket["status"] = "ready"
                    write_ticket(ticket_path, ticket)
                    tickets_written.append({"ticket_id": ticket_id, "action": "mark_ready"})
                    all_tickets = scan_repo(repo)
                if not all_deps_done(ticket, all_tickets):
                    skipped.append({"ticket_id": ticket_id, "reason": "dependencies_not_done"})
                    continue

                try:
                    result = self.dispatch(
                        ticket_id=ticket_id,
                        repo_path=str(repo),
                        context=request.get("dispatcher_context"),
                        source="orchestrator-action",
                        relay_command_seq=relay_command_seq,
                        relay_command_id=relay_command_id,
                        relay_intent_id=command_intent_id,
                    )
                except ValueError as e:
                    if not _started_anything():
                        raise
                    remaining = [
                        _relay_mutation_metadata(
                            "dispatch_ticket",
                            ticket_id=remaining_request["ticket_id"],
                            request_id=action_request_id,
                        )
                        for remaining_request in dispatch_requests[request_index:]
                    ]
                    return _cancel_and_return(remaining, str(e))
                run = result.get("run") or {}
                dispatches.append({
                    "ticket_id": ticket_id,
                    "run_id": run.get("id"),
                    "already_active": bool(result.get("already_active")),
                })

            if action_request_id:
                seen_request_ids.add(action_request_id)

            if command_id and command_store and command_store.get_private(
                command_id,
                intent_id=command_intent_id,
            ):
                action_kinds = {
                    str(action.get("kind") or "").strip().lower()
                    for action in actions
                    if isinstance(action, dict)
                }
                ticket_id = (
                    dispatches[0].get("ticket_id")
                    if dispatches
                    else (tickets_written[0].get("ticket_id") if tickets_written else None)
                )
                if dispatches:
                    command_status = "dispatched"
                    command_outcome = "ticket-dispatched"
                    message = f"Dispatched {ticket_id}." if ticket_id else "Ticket dispatched."
                elif "create_ticket" in action_kinds and tickets_written:
                    command_status = "created"
                    command_outcome = "ticket-created"
                    message = f"Created ticket {ticket_id}." if ticket_id else "Ticket created."
                elif action_kinds.intersection({"edit_ticket", "update_dependencies"}) and tickets_written:
                    command_status = "updated"
                    command_outcome = "ticket-updated"
                    message = f"Updated {ticket_id}." if ticket_id else "Ticket updated."
                else:
                    command_status = "rejected"
                    command_outcome = "mutation-rejected"
                    message = "No requested ticket mutation was applied."
                command_store.update_status(
                    command_id,
                    intent_id=command_intent_id,
                    status=command_status,
                    outcome=command_outcome,
                    ticket_id=ticket_id,
                    status_message=message,
                )

            return {
                "repo_path": str(repo),
                "request_id": action_request_id,
                "tickets_written": tickets_written,
                "dispatch_requests": _public_dispatch_requests(),
                "dispatches": dispatches,
                "skipped": skipped,
                "canceled": canceled,
            }

    def _create_orchestrator_ticket(self, repo: Path, action: dict[str, Any]) -> str:
        ticket_id = str(action.get("ticket_id") or "").strip().upper()
        title = _clean_required_text(action.get("title"), "title")
        priority = str(action.get("priority") or "medium").strip().lower()
        if priority not in ("urgent", "high", "medium", "low"):
            raise ValueError(f"invalid priority: {priority!r}")
        description = _clean_markdown(action.get("description"), "description")
        criteria = _acceptance_criteria_lines(action.get("acceptance_criteria"))
        sizing = _action_worker_sizing(action)
        depends_on = _ticket_id_list(action.get("depends_on"), "depends_on")
        if not ticket_id:
            ticket_id = _mint_ticket_id(repo)
        ticket_path = repo / ".orchestrator" / f"{ticket_id}.md"
        if ticket_path.exists():
            raise ValueError(f"ticket {ticket_id} already exists")
        _advance_ticket_config_past(repo, ticket_id)
        match = re.search(r"-(\d+)$", ticket_id)
        order = int(match.group(1)) if match else 0
        ticket = {
            "id": ticket_id,
            "title": title,
            "status": "backlog",
            "priority": priority,
            "execution_mode": _execution_mode(action.get("execution_mode")),
            "depends_on": depends_on,
            "run_id": None,
            "canceled": False,
            "order": order,
            "body": _structured_ticket_body(description, criteria),
            "_raw_fields": sizing,
        }
        write_ticket(ticket_path, ticket)
        _notify_orchestration_trace("ticket-created", ticket_id=ticket_id)
        return ticket_id

    def _edit_orchestrator_ticket(
        self,
        repo: Path,
        action: dict[str, Any],
        *,
        dependencies_only: bool,
    ) -> str:
        ticket_id = _clean_required_text(action.get("ticket_id"), "ticket_id").upper()
        ticket_path = repo / ".orchestrator" / f"{ticket_id}.md"
        if not ticket_path.is_file():
            raise ValueError(f"ticket {ticket_id} not found")
        ticket = read_ticket(ticket_path)
        if dependencies_only:
            ticket["depends_on"] = _ticket_id_list(action.get("depends_on"), "depends_on")
        else:
            _apply_ticket_action_fields(ticket, action)
        if ticket["status"] == "ready":
            ticket["status"] = "backlog"
        write_ticket(ticket_path, ticket)
        _notify_orchestration_trace("board-change", ticket_id=ticket_id)
        return ticket_id

    def _worker_creation_request(self, repo: Path, action: dict[str, Any]) -> dict[str, Any]:
        ticket_id = _clean_required_text(action.get("ticket_id"), "ticket_id").upper()
        ticket_path = repo / ".orchestrator" / f"{ticket_id}.md"
        if not ticket_path.is_file():
            raise ValueError(f"ticket {ticket_id} not found")
        ticket = read_ticket(ticket_path)
        assumptions = _ticket_id_list(
            action.get("dependency_assumptions", ticket["depends_on"]),
            "dependency_assumptions",
        )
        if assumptions != ticket["depends_on"]:
            raise ValueError(
                f"worker request for {ticket_id} has dependency_assumptions "
                f"{assumptions}, but ticket depends_on is {ticket['depends_on']}"
            )
        for field in WORKER_SIZING_FIELDS:
            requested = _clean_optional_text(action.get(field))
            actual = _required_sizing_value(ticket, field)
            if requested and requested != actual:
                raise ValueError(
                    f"worker request for {ticket_id} has {field}={requested!r}, "
                    f"but ticket has {actual!r}"
                )
        sizing = resolve_worker_sizing(ticket, self.agent_kind, general={})
        return {
            "ticket_id": ticket_id,
            "repo_path": str(repo),
            "dependency_assumptions": assumptions,
            "worker_model": sizing["worker_model"],
            "worker_effort": sizing["worker_effort"],
            "worker_sizing_rationale": sizing["worker_sizing_rationale"],
            "worker_provider_notes": sizing["worker_provider_notes"],
            "dispatcher_context": _clean_optional_text(action.get("dispatcher_context")),
        }

    def program_status(
        self,
        *,
        query: str | None = None,
        provider: str | None = None,
        limit: int = 8,
    ) -> dict:
        store = GraphifyCoreStore(self.graphify_path)
        counts = ingest_registered_projects(
            store,
            registry_path=self.program_registry_path,
            runs_db_path=self.runs.path,
            index_files=False,
        )
        if counts["projects"] == 0:
            return {
                "query": query or "summary",
                "provider": provider,
                "message": (
                    f"No registered projects found at {self.program_registry_path}. "
                    "Activate a project by path or start a Relay bridge in a git repo, then ask again."
                ),
                "items": [],
                "counts": {"projects": 0, "items": 0},
            }
        return build_program_status(
            store,
            query=query,
            provider=provider,
            limit=limit,
        )

    def program_dashboard(
        self,
        *,
        provider: str | None = None,
        limit: int = 0,
        trigger: str | None = None,
        repo_paths: list[str] | None = None,
    ) -> dict:
        self.sweep_program_ready_tickets(
            trigger=trigger or "program-board-refresh",
            repo_paths=repo_paths,
        )
        store = GraphifyCoreStore(self.graphify_path)
        ingest_registered_projects(
            store,
            registry_path=self.program_registry_path,
            runs_db_path=self.runs.path,
            index_files=False,
        )
        return build_program_dashboard(
            store,
            provider=provider,
            repo_paths=repo_paths,
            limit=limit,
        )

    def session_capture(
        self,
        *,
        repo_path: str | None = None,
        entries: list[dict[str, Any]] | None = None,
        ticket_id: str | None = None,
        run_id: int | str | None = None,
        provider: str | None = None,
        context: str | None = None,
        capture_id: str | None = None,
        source: str = "session_capture",
    ) -> dict:
        store = GraphifyCoreStore(self.graphify_path)
        counts = ingest_registered_projects(
            store,
            registry_path=self.program_registry_path,
            runs_db_path=self.runs.path,
            index_files=False,
        )
        result = capture_session_review(
            store,
            repo_path=repo_path,
            entries=entries,
            ticket_id=ticket_id,
            run_id=run_id,
            provider=provider,
            context=context,
            capture_id=capture_id,
            source=source,
        )
        result["ingest_counts"] = counts
        return result

    def cancel_run(self, run_id: int, *, prune_worktree: bool = True) -> dict:
        run = self.runs.get(run_id)
        if not run:
            raise ValueError(f"unknown run_id {run_id}")
        if run["state"] not in self.runs.ACTIVE_STATES and run["state"] != "Stalled":
            return {"canceled": False, "reason": f"run is in terminal state {run['state']}", "run": run}

        with self._workers_lock:
            worker = self._workers.get(run_id)
        if worker:
            worker.cancel()
            if worker.thread:
                worker.thread.join(timeout=10)
                if worker.thread.is_alive():
                    return {
                        "canceled": False,
                        "cancel_requested": True,
                        "reason": "worker is still terminating; snapshot and lease were preserved",
                        "run": self.runs.get(run_id),
                    }
        else:
            self.runs.update(run_id, state="Canceled",
                             last_error="Canceled (no live worker)", ended=True)
            if run.get("execution_mode") == SPIKE_EXECUTION_MODE:
                try:
                    self._spike_ticket_update(
                        self.runs.get(run_id) or run,
                        result=None,
                        incomplete_reason="Canceled by user.",
                    )
                except (OSError, RuntimeError, TicketParseError, ValueError) as e:
                    self.runs.update(run_id, last_error=f"Canceled; ticket reset failed: {e}")

        artifact_lifecycle = self._artifact_lifecycle(str(run.get("repo_path") or ""))
        if artifact_lifecycle is not None:
            current = self.runs.get(run_id) or run
            try:
                artifact_lifecycle.record_failure(
                    run_id=run_id,
                    ticket_id=str(run.get("ticket_id") or ""),
                    provider=str(run.get("provider_key") or ""),
                    reason=str(current.get("last_error") or "Canceled by user."),
                    canceled=True,
                )
            except Exception as error:  # noqa: BLE001
                raise ValueError(
                    f"run {run_id} stopped, but canonical cancellation could not be published: {error}"
                ) from error
            if prune_worktree:
                artifact_lifecycle.cleanup_snapshot(Path(str(run["workspace_path"])))

        result: dict = {"canceled": True, "run": self.runs.get(run_id)}
        if prune_worktree:
            repo_path = run.get("repo_path")
            if repo_path:
                if run.get("execution_mode") == SPIKE_EXECUTION_MODE:
                    removed, error = remove_spike_workspace(Path(run["workspace_path"]))
                else:
                    removed, error = remove_worktree(
                        repo_path, Path(run["workspace_path"])
                    )
                result["worktree_removed"] = removed
                if error:
                    result["worktree_error"] = error
                # Drop the throwaway branch ref so a re-dispatch starts fresh off the
                # current default branch instead of attaching to the old tip.
                if run.get("execution_mode") != SPIKE_EXECUTION_MODE:
                    delete_branch(repo_path, run["branch"])
        self._record_queue_drain_after_event(
            repo_path=run.get("repo_path"),
            trigger="run-canceled",
            drive_reviews=False,
        )
        return result

    def shutdown(self) -> None:
        with self._workers_lock:
            workers = list(self._workers.values())
        for w in workers:
            w.cancel()


# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------

def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: Any) -> None:
    body = json.dumps(payload, default=str).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _read_body(handler: BaseHTTPRequestHandler) -> dict:
    length = int(handler.headers.get("Content-Length", "0") or "0")
    if length <= 0:
        return {}
    raw = handler.rfile.read(length)
    if not raw:
        return {}
    try:
        data = json.loads(raw.decode("utf-8"))
        return data if isinstance(data, dict) else {}
    except json.JSONDecodeError:
        return {}


class Handler(BaseHTTPRequestHandler):
    daemon: Daemon  # set by serve()

    server_version = "RelayOrchestrator/0.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write(f"[orchestrator-http] {self.address_string()} {fmt % args}\n")

    def _route(self, method: str, path: str) -> tuple[int, Any]:
        parsed = urlparse(path)
        segments = [s for s in parsed.path.split("/") if s]
        query = parse_qs(parsed.query)

        try:
            if method == "GET" and segments == ["v1", "health"]:
                return 200, {"ok": True, "version": self.server_version}

            if method == "GET" and segments == ["v1", "runs"]:
                state = (query.get("state") or [None])[0]
                limit = int((query.get("limit") or ["100"])[0])
                return 200, {"runs": self.daemon.list_runs(state=state, limit=limit)}

            if method == "GET" and segments == ["v1", "queue-drains"]:
                repo_path = (query.get("repo_path") or [None])[0]
                include_terminal = str((query.get("include_terminal") or ["false"])[0]).lower() in {"1", "true", "yes"}
                limit = int((query.get("limit") or ["20"])[0])
                return 200, {
                    "queue_drains": self.daemon.list_queue_drains(
                        repo_path=repo_path,
                        include_terminal=include_terminal,
                        limit=limit,
                    )
                }

            if method == "GET" and segments == ["v1", "program", "status"]:
                status_query = (query.get("query") or ["summary"])[0]
                provider = (query.get("provider") or [None])[0]
                limit = int((query.get("limit") or ["8"])[0])
                return 200, self.daemon.program_status(
                    query=status_query,
                    provider=provider,
                    limit=limit,
                )

            if method == "GET" and segments == ["v1", "program", "dashboard"]:
                provider = (query.get("provider") or [None])[0]
                limit = int((query.get("limit") or ["0"])[0])
                trigger = (query.get("trigger") or ["program-board-refresh"])[0]
                repo_paths = query.get("repo_path")
                return 200, self.daemon.program_dashboard(
                    provider=provider,
                    limit=limit,
                    trigger=trigger,
                    repo_paths=repo_paths,
                )

            if method == "GET" and segments == ["v1", "orchestrator-sessions"]:
                repo_path = (query.get("repo_path") or [None])[0]
                limit = int((query.get("limit") or ["100"])[0])
                return 200, {
                    "orchestrator_sessions": self.daemon.list_orchestrator_sessions(
                        repo_path=repo_path,
                        limit=limit,
                    )
                }

            if method == "GET" and segments == ["v1", "messenger", "outcomes"]:
                repo_path = (query.get("repo_path") or [None])[0]
                provider = (query.get("provider") or [None])[0]
                limit = int((query.get("limit") or ["20"])[0])
                return 200, {
                    "outcomes": self.daemon.pending_messenger_outcomes(
                        repo_path=repo_path,
                        provider=provider,
                        limit=limit,
                    )
                }

            if (method == "POST" and len(segments) == 5
                    and segments[:3] == ["v1", "messenger", "outcomes"]
                    and segments[4] == "delivered"):
                outcome = self.daemon.mark_messenger_outcome_delivered(int(segments[3]))
                return (200 if outcome else 404), {"outcome": outcome}

            if (method == "POST" and len(segments) == 5
                    and segments[:3] == ["v1", "messenger", "outcomes"]
                    and segments[4] == "attempt"):
                self.daemon.record_messenger_outcome_attempt(int(segments[3]))
                return 202, {"ok": True}

            if method == "POST" and segments == ["v1", "orchestrator-session", "ensure"]:
                body = _read_body(self)
                result = self.daemon.ensure_orchestrator_session(
                    repo_path=body.get("repo_path", ""),
                    provider=body.get("provider"),
                    model=body.get("model"),
                    effort=body.get("effort"),
                    source=body.get("source"),
                    pid=body.get("pid"),
                    state=body.get("state") or "idle",
                    command_action_states=(
                        body.get("command_action_states")
                        if isinstance(body.get("command_action_states"), list)
                        else None
                    ),
                )
                session = result.get("orchestrator_session") or {}
                return (201 if session.get("created") else 200), result

            if method == "POST" and segments == ["v1", "orchestrator-session", "heartbeat"]:
                body = _read_body(self)
                result = self.daemon.heartbeat_orchestrator_session(
                    session_id=body.get("session_id"),
                    repo_path=body.get("repo_path"),
                    provider=body.get("provider"),
                    state=body.get("state"),
                )
                return 200, result

            if method == "POST" and segments == ["v1", "orchestrator-session", "stop"]:
                body = _read_body(self)
                result = self.daemon.stop_orchestrator_session(
                    session_id=body.get("session_id"),
                    repo_path=body.get("repo_path"),
                    reason=body.get("reason"),
                )
                return 200, result

            if method == "POST" and segments == ["v1", "orchestrator-session", "command"]:
                body = _read_body(self)
                result = self.daemon.record_orchestrator_command(
                    repo_path=body.get("repo_path", ""),
                    source_text=body.get("source_text", ""),
                    relay_command_seq=body.get("relay_command_seq"),
                    relay_command_id=body.get("relay_command_id", ""),
                    intent_id=body.get("intent_id"),
                    within_turn_order=body.get("within_turn_order"),
                    session_id=body.get("session_id"),
                    provider=body.get("provider"),
                    context=body.get("context"),
                    action=body.get("action"),
                    outcome=body.get("outcome"),
                    target=body.get("target"),
                    disposition=body.get("disposition"),
                    cancellation_scope=body.get("cancellation_scope"),
                    lifecycle_state=body.get("lifecycle_state"),
                    received_at=body.get("received_at"),
                    status=body.get("status") or "received",
                    defer_processing=bool(body.get("defer_processing")),
                )
                return 202, result

            if method == "POST" and segments == ["v1", "program", "capture"]:
                body = _read_body(self)
                result = self.daemon.session_capture(
                    repo_path=body.get("repo_path"),
                    entries=body.get("entries"),
                    ticket_id=body.get("ticket_id"),
                    run_id=body.get("run_id"),
                    provider=body.get("provider"),
                    context=body.get("context"),
                    capture_id=body.get("capture_id"),
                    source=body.get("source") or "session_capture",
                )
                return 201, result

            if method == "POST" and segments == ["v1", "orchestrator-actions"]:
                body = _read_body(self)
                result = self.daemon.apply_orchestrator_actions(
                    repo_path=body.get("repo_path", ""),
                    actions=body.get("actions") or [],
                    request_id=body.get("request_id"),
                    relay_command_seq=body.get("relay_command_seq"),
                    relay_command_id=body.get("relay_command_id"),
                    relay_intent_id=body.get("relay_intent_id"),
                )
                return 202, result

            if method == "POST" and segments == ["v1", "spikes", "follow-ups", "propose"]:
                body = _read_body(self)
                proposals = body.get("proposals")
                if proposals is not None and not isinstance(proposals, list):
                    raise ValueError("proposals must be a list")
                result = self.daemon.propose_spike_followups(
                    origin_repo_path=body.get("origin_repo_path", ""),
                    origin_ticket_id=body.get("origin_ticket_id", ""),
                    origin_run_id=int(body.get("origin_run_id") or 0),
                    proposals=proposals,
                    provider=body.get("provider"),
                )
                return (201 if result.get("created") else 200), result

            if (method == "POST" and len(segments) == 7
                    and segments[:3] == ["v1", "spikes", "follow-ups"]
                    and segments[4] == "proposals" and segments[6] == "review"):
                body = _read_body(self)
                return 200, self.daemon.review_spike_followup(
                    batch_id=segments[3],
                    proposal_id=segments[5],
                    decision=body.get("decision", ""),
                    updates=body.get("updates"),
                    relay_command_seq=body.get("relay_command_seq"),
                    relay_command_id=body.get("relay_command_id"),
                    relay_intent_id=body.get("relay_intent_id"),
                )

            if method == "POST" and segments == ["v1", "runs"]:
                body = _read_body(self)
                dispatch_args: dict[str, Any] = {
                    "ticket_id": body.get("ticket_id", ""),
                    "repo_path": body.get("repo_path", ""),
                    "context": body.get("context"),
                    "source": body.get("source") or "direct",
                }
                if body.get("relay_command_seq") is not None:
                    dispatch_args["relay_command_seq"] = body.get("relay_command_seq")
                if body.get("relay_command_id"):
                    dispatch_args["relay_command_id"] = body.get("relay_command_id")
                if body.get("relay_intent_id"):
                    dispatch_args["relay_intent_id"] = body.get("relay_intent_id")
                if body.get("project_scope_token"):
                    dispatch_args["project_scope_token"] = body.get("project_scope_token")
                result = self.daemon.dispatch(**dispatch_args)
                return (200 if result["already_active"] else 202), result

            if method == "POST" and segments == ["v1", "ready-sweep"]:
                body = _read_body(self)
                result = self.daemon.sweep_ready_tickets(
                    repo_path=body.get("repo_path", ""),
                    trigger=body.get("trigger"),
                    project_scope_token=body.get("project_scope_token"),
                )
                return 200, result

            if method == "POST" and segments == ["v1", "program", "ready-sweep"]:
                body = _read_body(self)
                result = self.daemon.sweep_program_ready_tickets(
                    trigger=body.get("trigger"),
                )
                return 200, result

            if method == "POST" and segments == ["v1", "queue-drain", "reconcile"]:
                body = _read_body(self)
                repo_paths = body.get("repo_paths")
                if isinstance(repo_paths, str):
                    repo_paths = [repo_paths]
                if body.get("repo_path"):
                    repo_paths = [body.get("repo_path")]
                result = self.daemon.reconcile_queue_drains(
                    repo_paths=repo_paths if isinstance(repo_paths, list) else None,
                    trigger=body.get("trigger"),
                )
                return 200, result

            if (method == "POST" and len(segments) == 4
                    and segments[:2] == ["v1", "queue-drains"]
                    and segments[3] == "cancel"):
                body = _read_body(self)
                result = self.daemon.cancel_queue_drain(
                    segments[2],
                    reason=body.get("reason"),
                )
                return 200, result

            if method == "GET" and len(segments) == 3 and segments[:2] == ["v1", "runs"]:
                run = self.daemon.get_run(int(segments[2]))
                return (200 if run else 404), {"run": run}

            if (method == "POST" and len(segments) == 4
                    and segments[:2] == ["v1", "runs"] and segments[3] == "outcome"):
                body = _read_body(self)
                return 202, self.daemon.submit_worker_outcome(int(segments[2]), body)

            if (method == "GET" and len(segments) == 4
                    and segments[:2] == ["v1", "runs"] and segments[3] == "review"):
                result = self.daemon.inspect_run_for_review(int(segments[2]))
                return 200, result

            if (method == "POST" and len(segments) == 4
                    and segments[:2] == ["v1", "runs"] and segments[3] == "review"):
                body = _read_body(self)
                return 202, self.daemon.dispatch_review_worker(
                    int(segments[2]),
                    source="review-endpoint",
                    context=body.get("context"),
                )

            if (method == "POST" and len(segments) == 5
                    and segments[:2] == ["v1", "runs"]
                    and segments[3] == "review" and segments[4] == "decision"):
                body = _read_body(self)
                decision = str(body.get("decision") or "").strip().lower()
                if decision == "accept":
                    return 200, self.daemon.accept_worker_run(int(segments[2]))
                if decision == "retry":
                    return 202, self.daemon.request_worker_retry(
                        int(segments[2]),
                        reason=body.get("reason"),
                        redispatch=bool(body.get("redispatch", True)),
                    )
                raise ValueError("decision must be 'accept' or 'retry'")

            if (method == "POST" and len(segments) == 4
                    and segments[:2] == ["v1", "runs"] and segments[3] == "cancel"):
                body = _read_body(self)
                prune = bool(body.get("prune_worktree", True))
                result = self.daemon.cancel_run(int(segments[2]), prune_worktree=prune)
                return 200, result

            if method == "POST" and segments == ["v1", "runs", "reconcile-preserved"]:
                body = _read_body(self)
                result = self.daemon.reconcile_preserved_run(
                    repo_path=body.get("repo_path", ""),
                    ticket_id=body.get("ticket_id", ""),
                )
                return 200, result

            if (method == "POST" and len(segments) == 4
                    and segments[:2] == ["v1", "runs"] and segments[3] == "resume-verification"):
                body = _read_body(self)
                result = self.daemon.resume_verification_blocked(
                    int(segments[2]),
                    reason=body.get("reason", ""),
                    redispatch=bool(body.get("redispatch", True)),
                )
                return (202 if result.get("redispatched") else 200), result

            return 404, {"error": f"no route for {method} {parsed.path}"}
        except ValueError as e:
            return 400, {"error": str(e)}
        except RuntimeError as e:
            return 500, {"error": str(e)}

    def do_GET(self) -> None:
        status, payload = self._route("GET", self.path)
        _json_response(self, status, payload)

    def do_POST(self) -> None:
        status, payload = self._route("POST", self.path)
        _json_response(self, status, payload)


def _bind_port(preferred: int) -> tuple[ThreadingHTTPServer, int]:
    """Bind preferred port; if taken (or preferred=0), pick an ephemeral one. Returns (server, actual_port)."""
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", preferred), Handler)
    except OSError:
        srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    # server_address is the truth — kernel may have picked any port when preferred=0
    # or when SO_REUSEADDR resolves a benign collision.
    return srv, srv.server_address[1]


def _write_port_file(port: int) -> None:
    try:
        PORT_FILE.write_text(str(port))
    except OSError as e:
        print(f"[orchestrator] could not write port file {PORT_FILE}: {e}", file=sys.stderr)


def _clear_port_file() -> None:
    try:
        PORT_FILE.unlink()
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

def serve(daemon: Daemon) -> None:
    Handler.daemon = daemon
    server, port = _bind_port(daemon.port)
    daemon.port = port
    _write_port_file(port)
    print(f"[orchestrator] listening on http://127.0.0.1:{port}", file=sys.stderr)

    stop = threading.Event()

    def _signal_handler(signum, _frame):
        print(f"[orchestrator] caught signal {signum}, shutting down", file=sys.stderr)
        stop.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, _signal_handler)
        except (OSError, ValueError):
            pass

    # Periodic prune sweep: transitions keep the index current, but a run that
    # completes and then sees no further transitions would linger past its
    # retention window without this. Rewriting drops expired entries.
    def _prune_loop():
        while not stop.wait(30):
            daemon.runs.write_index()

    threading.Thread(target=_prune_loop, name="runs-index-pruner", daemon=True).start()

    def _command_loop():
        while not stop.wait(2):
            try:
                daemon.process_orchestrator_commands(limit=10)
            except Exception as e:  # noqa: BLE001 - keep the HTTP daemon alive.
                print(f"[orchestrator] command processing loop failed: {e}", file=sys.stderr)

    threading.Thread(target=_command_loop, name="orchestrator-command-loop", daemon=True).start()

    def _queue_drain_loop():
        while not stop.wait(QUEUE_DRAIN_MONITOR_INTERVAL_SECONDS):
            try:
                daemon.reconcile_queue_drains(trigger="queue-drain-monitor")
            except Exception as e:  # noqa: BLE001 - keep the HTTP daemon alive.
                print(f"[orchestrator] queue-drain monitor failed: {e}", file=sys.stderr)

    threading.Thread(target=_queue_drain_loop, name="queue-drain-monitor", daemon=True).start()

    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        daemon.shutdown()
        _clear_port_file()
        print("[orchestrator] stopped", file=sys.stderr)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="relay-runner orchestrator daemon")
    parser.add_argument("--config", help="path to config.toml (otherwise uses default location)")
    parser.add_argument("--print-port", action="store_true",
                        help="print the bound port to stdout (after binding) for callers that scrape it")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    cfg = load_config(args.config) if args.config else load_config()
    daemon = Daemon(cfg)
    if args.print_port:
        # Print early — port file still gets written by serve().
        print(daemon.port)
    serve(daemon)


if __name__ == "__main__":
    main()
