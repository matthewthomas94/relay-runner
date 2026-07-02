"""Ingest registered Relay Runner projects into Graphify Core."""

from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import quote

from graphify_core import (
    EDGE_AWAITS_MERGE,
    EDGE_BELONGS_TO,
    EDGE_CONTAINS,
    EDGE_DEPENDS_ON,
    EDGE_EXECUTES,
    EDGE_MENTIONS_FILE,
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
    index_files: bool = True,
) -> dict[str, int]:
    """Build the Graphify Core program graph from registered project sources.

    The registry, project ticket files, run logs, and run-history database are
    read-only inputs. All writes go through the provided GraphifyCoreStore.
    """
    registry = _load_registry(Path(registry_path))
    active_project_id = registry.get("activeProjectID")
    active_project_path = _clean_path(active_project_id)
    active_workspace_root_path = _clean_path(registry.get("activeWorkspaceRootID"))
    workspace_root_paths = _workspace_root_paths(registry)
    workspace_roots_to_filter = {
        path
        for path in workspace_root_paths
        if path != active_project_path or path == active_workspace_root_path
    }
    registered_projects = registry.get("projects")
    if not isinstance(registered_projects, list):
        registered_projects = []

    counts = {
        "projects": 0,
        "tickets": 0,
        "tickets_deleted": 0,
        "dependencies": 0,
        "runs": 0,
        "runs_deleted": 0,
        "providers": 0,
        "files_indexed": 0,
        "files_unchanged": 0,
        "files_deleted": 0,
    }
    projects_by_repo: dict[str, dict[str, Any]] = {}
    tickets_by_repo: dict[str, dict[str, dict[str, Any]]] = {}

    for repo_path in workspace_roots_to_filter:
        _delete_existing_project_graph(store, repo_path)

    for record in registered_projects:
        if not isinstance(record, dict):
            continue
        repo_path = _repo_path(record)
        if repo_path is None:
            continue
        if repo_path in workspace_roots_to_filter:
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
                    "worker_model": _ticket_field(ticket, "worker_model"),
                    "worker_effort": _ticket_field(ticket, "worker_effort"),
                    "worker_sizing_rationale": _ticket_field(ticket, "worker_sizing_rationale"),
                    "worker_provider_notes": _ticket_field(ticket, "worker_provider_notes"),
                    "source_path": str(ticket.get("_path", "")),
                    "markdown": ticket["body"],
                },
            )
            repo_ticket_nodes[ticket["id"]] = ticket_node
            counts["tickets"] += 1
            store.upsert_edge(src_id=ticket_node["id"], dst_id=project["id"], kind=EDGE_BELONGS_TO)
            store.upsert_edge(src_id=project["id"], dst_id=ticket_node["id"], kind=EDGE_CONTAINS)

        counts["tickets_deleted"] += _delete_missing_ticket_nodes(
            store,
            project=project,
            seen_ticket_ids=set(repo_ticket_nodes),
        )

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

        if index_files:
            file_counts = _index_project_files(
                store,
                project=project,
                repo_path=Path(repo_path),
                ticket_nodes=list(repo_ticket_nodes.values()),
            )
            for key, value in file_counts.items():
                counts[key] += value

        tickets_by_repo[repo_path] = repo_ticket_nodes

    seen_run_stable_keys: set[str] = set()
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
            "worker_model": run.get("worker_model"),
            "worker_effort": run.get("worker_effort"),
            "worker_sizing_rationale": run.get("worker_sizing_rationale"),
            "worker_provider_notes": run.get("worker_provider_notes"),
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
            stable_key=_run_key(run.get("id")),
            project_id=project["id"],
            title=f"{ticket_id} run {run.get('id')}".strip(),
            body=body,
        )
        seen_run_stable_keys.add(run_node["stable_key"])
        counts["runs"] += 1
        store.upsert_edge(src_id=run_node["id"], dst_id=project["id"], kind=EDGE_BELONGS_TO)
        store.upsert_edge(src_id=project["id"], dst_id=run_node["id"], kind=EDGE_CONTAINS)
        if ticket_node is not None:
            store.upsert_edge(src_id=run_node["id"], dst_id=ticket_node["id"], kind=EDGE_EXECUTES)
            if program_state == "awaiting_merge":
                store.upsert_edge(src_id=ticket_node["id"], dst_id=run_node["id"], kind=EDGE_AWAITS_MERGE)
        if provider_node is not None:
            store.upsert_edge(src_id=run_node["id"], dst_id=provider_node["id"], kind=EDGE_USES_PROVIDER)

    if runs_db_path is not None:
        counts["runs_deleted"] = _delete_missing_run_nodes(
            store,
            projects=projects_by_repo.values(),
            seen_run_stable_keys=seen_run_stable_keys,
        )

    return counts


def _load_registry(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def _workspace_root_paths(registry: dict[str, Any]) -> set[str]:
    roots = registry.get("workspaceRoots")
    if not isinstance(roots, list):
        return set()
    paths: set[str] = set()
    for record in roots:
        if not isinstance(record, dict):
            continue
        path = _clean_path(record.get("rootPath") or record.get("id"))
        if path is not None:
            paths.add(path)
    return paths


_IGNORED_CODE_INDEX_DIRS = {
    ".git",
    ".hg",
    ".svn",
    ".orchestrator",
    ".relay",
    ".build",
    ".dart_tool",
    ".gradle",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".swiftpm",
    ".venv",
    "__pycache__",
    "build",
    "DerivedData",
    "dist",
    "node_modules",
    "Pods",
    "target",
    "vendor",
}

_INDEXABLE_SUFFIXES = {
    ".c",
    ".cc",
    ".cpp",
    ".css",
    ".go",
    ".h",
    ".hpp",
    ".html",
    ".java",
    ".js",
    ".json",
    ".jsx",
    ".kt",
    ".m",
    ".md",
    ".mm",
    ".plist",
    ".py",
    ".rb",
    ".rs",
    ".scss",
    ".sh",
    ".sql",
    ".swift",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}

_INDEXABLE_NAMES = {
    ".gitignore",
    "AGENTS.md",
    "CLAUDE.md",
    "Dockerfile",
    "Makefile",
    "Package.swift",
    "README",
    "README.md",
}

_LANGUAGE_BY_SUFFIX = {
    ".c": "c",
    ".cc": "cpp",
    ".cpp": "cpp",
    ".css": "css",
    ".go": "go",
    ".h": "c",
    ".hpp": "cpp",
    ".html": "html",
    ".java": "java",
    ".js": "javascript",
    ".json": "json",
    ".jsx": "javascript",
    ".kt": "kotlin",
    ".m": "objective-c",
    ".md": "markdown",
    ".mm": "objective-cpp",
    ".plist": "plist",
    ".py": "python",
    ".rb": "ruby",
    ".rs": "rust",
    ".scss": "scss",
    ".sh": "shell",
    ".sql": "sql",
    ".swift": "swift",
    ".toml": "toml",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".txt": "text",
    ".xml": "xml",
    ".yaml": "yaml",
    ".yml": "yaml",
}

_MAX_INDEX_BYTES = 1_000_000
_CHUNK_LINES = 120


def _index_project_files(
    store: GraphifyCoreStore,
    *,
    project: dict[str, Any],
    repo_path: Path,
    ticket_nodes: list[dict[str, Any]],
) -> dict[str, int]:
    counts = {"files_indexed": 0, "files_unchanged": 0, "files_deleted": 0}
    if not repo_path.is_dir():
        return counts

    seen: set[str] = set()
    for path in _iter_indexable_files(repo_path):
        try:
            stat = path.stat()
        except OSError:
            continue
        if stat.st_size > _MAX_INDEX_BYTES:
            continue

        rel_path = path.relative_to(repo_path).as_posix()
        seen.add(rel_path)
        mtime_ns = _mtime_ns(stat)
        manifest = store.get_file_manifest(project_id=project["id"], rel_path=rel_path)
        if (
            manifest is not None
            and manifest["deleted_at"] is None
            and manifest["size_bytes"] == stat.st_size
            and manifest["mtime_ns"] == mtime_ns
        ):
            counts["files_unchanged"] += 1
            file_node = store.get_node(manifest["id"])
            if file_node is not None:
                _link_ticket_file_mentions(store, ticket_nodes, file_node=file_node, rel_path=rel_path)
            continue

        text = _read_text_file(path)
        if text is None:
            seen.discard(rel_path)
            continue
        manifest = store.upsert_file_index(
            project_id=project["id"],
            rel_path=rel_path,
            language=_language_for_path(path),
            size_bytes=stat.st_size,
            mtime_ns=mtime_ns,
            chunks=_chunk_text(text),
        )
        counts["files_indexed"] += 1
        file_node = store.get_node(manifest["id"])
        if file_node is not None:
            _link_ticket_file_mentions(store, ticket_nodes, file_node=file_node, rel_path=rel_path)

    counts["files_deleted"] = store.mark_missing_files_deleted(
        project_id=project["id"],
        seen_rel_paths=seen,
    )
    return counts


def _iter_indexable_files(repo_path: Path):
    for dirpath, dirnames, filenames in os.walk(repo_path):
        dirnames[:] = [
            dirname
            for dirname in sorted(dirnames)
            if dirname not in _IGNORED_CODE_INDEX_DIRS and not dirname.endswith(".app")
        ]
        for filename in sorted(filenames):
            path = Path(dirpath) / filename
            if path.is_symlink():
                continue
            if _is_indexable_path(path):
                yield path


def _is_indexable_path(path: Path) -> bool:
    name = path.name
    if name in _INDEXABLE_NAMES:
        return True
    if name.startswith("."):
        return False
    return path.suffix.lower() in _INDEXABLE_SUFFIXES


def _read_text_file(path: Path) -> str | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def _chunk_text(text: str) -> list[dict[str, Any]]:
    lines = text.splitlines()
    chunks: list[dict[str, Any]] = []
    for start in range(0, len(lines), _CHUNK_LINES):
        chunk_lines = lines[start : start + _CHUNK_LINES]
        chunks.append(
            {
                "chunk_ordinal": len(chunks),
                "start_line": start + 1,
                "end_line": start + len(chunk_lines),
                "text": "\n".join(chunk_lines),
            }
        )
    if not chunks and text:
        chunks.append({"chunk_ordinal": 0, "start_line": 1, "end_line": 1, "text": text})
    return chunks


def _language_for_path(path: Path) -> str:
    if path.name in {"Dockerfile", "Makefile"}:
        return path.name.lower()
    if path.name == "Package.swift":
        return "swift"
    return _LANGUAGE_BY_SUFFIX.get(path.suffix.lower(), "text")


def _mtime_ns(stat: os.stat_result) -> int:
    return int(getattr(stat, "st_mtime_ns", int(stat.st_mtime * 1_000_000_000)))


def _link_ticket_file_mentions(
    store: GraphifyCoreStore,
    ticket_nodes: list[dict[str, Any]],
    *,
    file_node: dict[str, Any],
    rel_path: str,
) -> None:
    for ticket_node in ticket_nodes:
        body = ticket_node.get("body", {})
        haystack = f"{ticket_node.get('title') or ''}\n{body.get('markdown') or ''}"
        if rel_path in haystack:
            store.upsert_edge(
                src_id=ticket_node["id"],
                dst_id=file_node["id"],
                kind=EDGE_MENTIONS_FILE,
                body={"source": "ticket_markdown", "rel_path": rel_path},
            )


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


def _run_key(run_id: Any) -> str:
    return f"run:{run_id}"


def _delete_existing_project_graph(store: GraphifyCoreStore, repo_path: str) -> None:
    project = store.find_node(kind=NODE_PROJECT, stable_key=_project_key(repo_path))
    if project is None:
        return
    for node in store.nodes(project_id=project["id"]):
        store.delete_node(node["id"])
    store.delete_node(project["id"])


def _delete_missing_ticket_nodes(
    store: GraphifyCoreStore,
    *,
    project: dict[str, Any],
    seen_ticket_ids: set[str],
) -> int:
    seen_stable_keys = {f"{project['stable_key']}:{ticket_id}" for ticket_id in seen_ticket_ids}
    deleted = 0
    for node in store.nodes(kind=NODE_TICKET, project_id=project["id"]):
        if node["stable_key"] in seen_stable_keys:
            continue
        if store.delete_node(node["id"]):
            deleted += 1
    return deleted


def _delete_missing_run_nodes(
    store: GraphifyCoreStore,
    *,
    projects: Iterable[dict[str, Any]],
    seen_run_stable_keys: set[str],
) -> int:
    project_ids = {project["id"] for project in projects}
    deleted = 0
    for node in store.nodes(kind=NODE_RUN):
        if node.get("project_id") not in project_ids:
            continue
        if node["stable_key"] in seen_run_stable_keys:
            continue
        if store.delete_node(node["id"]):
            deleted += 1
    return deleted


def _ticket_state(ticket: dict[str, Any]) -> str:
    if ticket.get("canceled"):
        return "canceled"
    return str(ticket.get("status") or "unknown")


def _ticket_field(ticket: dict[str, Any], field: str) -> str | None:
    raw = ticket.get("_raw_fields")
    if not isinstance(raw, dict):
        return None
    value = str(raw.get(field) or "").strip()
    return value or None


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
    if state in {"awaiting_review", "awaitingreview"}:
        return "awaiting_review"
    if state in {"merge_conflict", "mergeconflict"}:
        return "merge_conflict"
    if state == "merged":
        return "merged"
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
    if state in {"awaiting_review", "merge_conflict"}:
        return state
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
