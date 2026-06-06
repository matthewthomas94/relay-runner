"""Ingest registered Relay Runner projects into Graphify Core."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any
from urllib.parse import quote

from graphify_core import (
    EDGE_AWAITS_MERGE,
    EDGE_BELONGS_TO,
    EDGE_CONTAINS,
    EDGE_DEPENDS_ON,
    EDGE_EXECUTES,
    EDGE_USES_PROVIDER,
    NODE_AGENT_PROVIDER,
    NODE_PROJECT,
    NODE_RUN,
    NODE_TICKET,
    GraphifyCoreStore,
)
from tickets import scan_repo


def ingest_registered_projects(
    store: GraphifyCoreStore,
    *,
    registry_path: str | Path,
    runs_db_path: str | Path | None = None,
) -> dict[str, int]:
    """Build the Graphify Core program graph from registered project sources.

    The registry, project ticket files, run logs, and run-history database are
    read-only inputs. All writes go through the provided GraphifyCoreStore.
    """
    registry = _load_registry(Path(registry_path))
    active_project_id = registry.get("activeProjectID")
    registered_projects = registry.get("projects")
    if not isinstance(registered_projects, list):
        registered_projects = []

    counts = {
        "projects": 0,
        "tickets": 0,
        "dependencies": 0,
        "runs": 0,
        "providers": 0,
    }
    projects_by_repo: dict[str, dict[str, Any]] = {}
    tickets_by_repo: dict[str, dict[str, dict[str, Any]]] = {}

    for record in registered_projects:
        if not isinstance(record, dict):
            continue
        repo_path = _repo_path(record)
        if repo_path is None:
            continue

        project = store.upsert_node(
            kind=NODE_PROJECT,
            stable_key=_project_key(repo_path),
            title=str(record.get("displayName") or record.get("alias") or Path(repo_path).name),
            body={
                "project_id": record.get("id") or repo_path,
                "repo_path": repo_path,
                "root_path": repo_path,
                "alias": record.get("alias"),
                "display_name": record.get("displayName"),
                "active": (record.get("id") or repo_path) == active_project_id,
                "last_seen_at": record.get("lastSeenAt"),
                "last_activation_source": record.get("lastActivationSource"),
                "providers": record.get("providers") if isinstance(record.get("providers"), dict) else {},
            },
        )
        counts["projects"] += 1
        projects_by_repo[repo_path] = project

        for provider_key in _registry_provider_keys(record):
            _upsert_provider(store, provider_key)
            counts["providers"] += 1

        repo_ticket_nodes: dict[str, dict[str, Any]] = {}
        tickets = scan_repo(Path(repo_path))
        for ticket in tickets:
            ticket_node = store.upsert_node(
                kind=NODE_TICKET,
                stable_key=_ticket_key(repo_path, ticket["id"]),
                project_id=project["id"],
                title=ticket["title"],
                body={
                    "ticket_id": ticket["id"],
                    "state": _ticket_state(ticket),
                    "status": ticket["status"],
                    "priority": ticket["priority"],
                    "depends_on": ticket["depends_on"],
                    "run_id": ticket["run_id"],
                    "canceled": ticket["canceled"],
                    "source_path": str(ticket.get("_path", "")),
                    "markdown": ticket["body"],
                },
            )
            repo_ticket_nodes[ticket["id"]] = ticket_node
            counts["tickets"] += 1
            store.upsert_edge(src_id=ticket_node["id"], dst_id=project["id"], kind=EDGE_BELONGS_TO)
            store.upsert_edge(src_id=project["id"], dst_id=ticket_node["id"], kind=EDGE_CONTAINS)

        for ticket in tickets:
            ticket_node = repo_ticket_nodes.get(ticket["id"])
            if ticket_node is None:
                continue
            for dep_id in ticket["depends_on"]:
                dep_node = repo_ticket_nodes.get(dep_id)
                if dep_node is None:
                    continue
                store.upsert_edge(
                    src_id=ticket_node["id"],
                    dst_id=dep_node["id"],
                    kind=EDGE_DEPENDS_ON,
                    body={"source": "ticket_frontmatter"},
                )
                counts["dependencies"] += 1

        tickets_by_repo[repo_path] = repo_ticket_nodes

    for run in _read_runs(Path(runs_db_path)) if runs_db_path is not None else []:
        repo_path = _clean_path(run.get("repo_path"))
        if repo_path is None:
            continue
        project = projects_by_repo.get(repo_path)
        if project is None:
            continue

        ticket_id = str(run.get("ticket_id") or "").strip()
        ticket_node = tickets_by_repo.get(repo_path, {}).get(ticket_id)
        provider_key, provider_source = _provider_for_run(run)
        provider_node = None
        if provider_key:
            provider_node = _upsert_provider(store, provider_key)
            counts["providers"] += 1

        state = _run_state(run.get("state"))
        program_state = _program_state(state, ticket_node)
        body = {
            "run_id": run.get("id"),
            "ticket_id": ticket_id,
            "attempt": run.get("attempt"),
            "provider_key": provider_key,
            "model_alias": _first_present(run, "model_alias", "model"),
            "state": state,
            "raw_state": run.get("state"),
            "program_state": program_state,
            "branch": run.get("branch"),
            "workspace_path": run.get("workspace_path"),
            "log_path": run.get("log_path"),
            "started_at": run.get("started_at"),
            "ended_at": run.get("ended_at"),
            "exit_code": run.get("exit_code"),
            "last_error": run.get("last_error"),
            "activity": run.get("activity"),
            "activity_at": run.get("activity_at"),
            "provider": {"key": provider_key, "source": provider_source} if provider_key else None,
        }
        run_node = store.upsert_node(
            kind=NODE_RUN,
            stable_key=f"run:{run.get('id')}",
            project_id=project["id"],
            title=f"{ticket_id} run {run.get('id')}".strip(),
            body=body,
        )
        counts["runs"] += 1
        store.upsert_edge(src_id=run_node["id"], dst_id=project["id"], kind=EDGE_BELONGS_TO)
        store.upsert_edge(src_id=project["id"], dst_id=run_node["id"], kind=EDGE_CONTAINS)
        if ticket_node is not None:
            store.upsert_edge(src_id=run_node["id"], dst_id=ticket_node["id"], kind=EDGE_EXECUTES)
            if program_state == "awaiting_merge":
                store.upsert_edge(src_id=ticket_node["id"], dst_id=run_node["id"], kind=EDGE_AWAITS_MERGE)
        if provider_node is not None:
            store.upsert_edge(src_id=run_node["id"], dst_id=provider_node["id"], kind=EDGE_USES_PROVIDER)

    return counts


def _load_registry(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def _repo_path(record: dict[str, Any]) -> str | None:
    return _clean_path(record.get("repoPath") or record.get("id"))


def _clean_path(value: Any) -> str | None:
    text = str(value or "").strip()
    if not text:
        return None
    return str(Path(text).expanduser().resolve())


def _project_key(repo_path: str) -> str:
    return f"repo:{repo_path}"


def _ticket_key(repo_path: str, ticket_id: str) -> str:
    return f"{_project_key(repo_path)}:{ticket_id}"


def _ticket_state(ticket: dict[str, Any]) -> str:
    if ticket.get("canceled"):
        return "canceled"
    return str(ticket.get("status") or "unknown")


def _registry_provider_keys(record: dict[str, Any]) -> list[str]:
    providers = record.get("providers")
    if not isinstance(providers, dict):
        return []
    return [_normalize_provider(key) for key in providers if _normalize_provider(key)]


def _upsert_provider(store: GraphifyCoreStore, provider_key: str) -> dict[str, Any]:
    provider_key = _normalize_provider(provider_key)
    return store.upsert_node(
        kind=NODE_AGENT_PROVIDER,
        stable_key=provider_key,
        title=_provider_title(provider_key),
        body={"provider_key": provider_key},
    )


def _provider_title(provider_key: str) -> str:
    known = {"codex": "Codex", "claude": "Claude"}
    return known.get(provider_key, provider_key.replace("_", " ").title())


def _read_runs(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    uri = "file:" + quote(str(path), safe="/:") + "?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute("SELECT * FROM runs ORDER BY id").fetchall()
        finally:
            conn.close()
    except sqlite3.Error:
        return []
    return [dict(row) for row in rows]


def _provider_for_run(run: dict[str, Any]) -> tuple[str | None, str | None]:
    for key in ("provider_key", "provider", "agent_kind", "agent_provider", "agent"):
        provider_key = _normalize_provider(run.get(key))
        if provider_key:
            return provider_key, f"run.{key}"

    provider_key = _infer_provider_from_log(run.get("log_path"))
    if provider_key:
        return provider_key, "run.log"
    return None, None


def _normalize_provider(value: Any) -> str:
    text = str(value or "").strip().lower()
    if not text:
        return ""
    if text in ("codex", "claude"):
        return text
    if "codex" in text:
        return "codex"
    if "claude" in text:
        return "claude"
    return text.replace(" ", "_").replace("-", "_")


def _infer_provider_from_log(path_value: Any) -> str | None:
    path = _clean_path(path_value)
    if path is None:
        return None
    try:
        with Path(path).open() as handle:
            for _ in range(50):
                line = handle.readline()
                if not line:
                    break
                provider = _provider_from_log_line(line)
                if provider:
                    return provider
    except OSError:
        return None
    return None


def _provider_from_log_line(line: str) -> str | None:
    stripped = line.strip()
    if not stripped:
        return None
    try:
        payload = json.loads(stripped)
    except json.JSONDecodeError:
        lower = stripped.lower()
        if "codex" in lower:
            return "codex"
        if "claude" in lower:
            return "claude"
        return None

    event_type = str(payload.get("type") or "")
    if event_type.startswith(("thread.", "item.", "turn.")):
        return "codex"
    if event_type in {"assistant", "user", "result", "system"}:
        return "claude"
    return _normalize_provider(payload.get("provider")) or None


def _run_state(raw_state: Any) -> str:
    state = str(raw_state or "").strip().lower().replace("-", "_").replace(" ", "_")
    if state in {"claimed", "running"}:
        return "active"
    if state in {"succeeded", "success", "done"}:
        return "succeeded"
    if state in {"failed", "failure", "timed_out", "timeout"}:
        return "failed"
    if state == "stalled":
        return "stalled"
    if state in {"canceled", "cancelled"}:
        return "canceled"
    return state or "unknown"


def _program_state(state: str, ticket_node: dict[str, Any] | None) -> str:
    if state != "succeeded" or ticket_node is None:
        return state
    ticket_state = str(ticket_node["body"].get("state") or "")
    if ticket_state != "done":
        return "awaiting_merge"
    return "succeeded"


def _first_present(values: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in values and values[key] is not None:
            return values[key]
    return None
