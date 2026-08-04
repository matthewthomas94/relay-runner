"""Native session review capture into Graphify Core."""

from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path
from typing import Any

try:
    from services.artifact_store import ArtifactStore
except ModuleNotFoundError:  # Installed direct-script layout.
    from artifact_store import ArtifactStore  # type: ignore[no-redef]

from graphify_core import (
    EDGE_BELONGS_TO,
    EDGE_BLOCKS,
    EDGE_CONTAINS,
    EDGE_RELATED_TO,
    NODE_DECISION,
    NODE_IDEA,
    NODE_PROGRAM_EVENT,
    NODE_PROJECT,
    NODE_RISK,
    NODE_RUN,
    NODE_STATUS,
    NODE_TICKET,
    GraphifyCoreStore,
)
from program_artifacts import (
    durable_program_event,
    ingest_project_program_events,
    write_program_events,
)
from tickets import scan_repo

CAPTURE_NODE_KINDS = (
    NODE_PROGRAM_EVENT,
    NODE_DECISION,
    NODE_RISK,
    NODE_IDEA,
    NODE_STATUS,
)

_KIND_ALIASES = {
    "event": NODE_PROGRAM_EVENT,
    "program_event": NODE_PROGRAM_EVENT,
    "program-event": NODE_PROGRAM_EVENT,
    "shipped": NODE_PROGRAM_EVENT,
    "shipped_work": NODE_PROGRAM_EVENT,
    "started": NODE_PROGRAM_EVENT,
    "started_work": NODE_PROGRAM_EVENT,
    "note": NODE_PROGRAM_EVENT,
    "notes": NODE_PROGRAM_EVENT,
    "decision": NODE_DECISION,
    "risk": NODE_RISK,
    "blocker": NODE_RISK,
    "blocked": NODE_RISK,
    "idea": NODE_IDEA,
    "status": NODE_STATUS,
}

_EVENT_TYPES = {
    "event": "note",
    "program_event": "note",
    "program-event": "note",
    "shipped": "shipped_work",
    "shipped_work": "shipped_work",
    "started": "started_work",
    "started_work": "started_work",
    "note": "note",
    "notes": "note",
}


class SessionCaptureError(ValueError):
    pass


def capture_session_review(
    store: GraphifyCoreStore,
    *,
    repo_path: str | Path | None = None,
    entries: list[dict[str, Any]] | None = None,
    ticket_id: str | None = None,
    run_id: int | str | None = None,
    provider: str | None = None,
    context: str | None = None,
    capture_id: str | None = None,
    source: str = "session_capture",
    occurred_at: float | None = None,
    artifact_store: ArtifactStore | None = None,
    artifact_device_id: str | None = None,
) -> dict[str, Any]:
    """Write structured session review entries to the selected Program authority.

    The caller supplies structured entries and any provider transcript context
    it has. Artifact-enabled projects commit a privacy-filtered durable event
    before refreshing Graphify; legacy projects retain the old projection-only
    path until their reviewed migration. Codex and Claude share both schemas.
    """
    normalized_entries = _normalize_entries(entries)
    repo = _resolve_repo_path(repo_path)
    project = _resolve_or_create_project(store, repo)
    default_ticket = _resolve_ticket(store, repo=repo, project=project, ticket_id=ticket_id)
    default_run = _resolve_run(store, run_id=run_id)
    occurred_at = float(time.time() if occurred_at is None else occurred_at)
    capture_id = _capture_id(
        capture_id,
        repo=repo,
        entries=normalized_entries,
        ticket_id=ticket_id,
        run_id=run_id,
        occurred_at=occurred_at,
    )
    provider_key = _normalize_provider(provider)

    counts = {kind: 0 for kind in CAPTURE_NODE_KINDS}
    links = 0
    created: list[dict[str, Any]] = []

    resolved: list[tuple[
        int,
        dict[str, Any],
        dict[str, Any] | None,
        dict[str, Any] | None,
        dict[str, Any] | None,
    ]] = []
    durable_documents: list[dict[str, Any]] = []

    for index, entry in enumerate(normalized_entries):
        entry_ticket = _resolve_ticket(
            store,
            repo=repo,
            project=project,
            ticket_id=entry.get("ticket_id") or ticket_id,
        ) or default_ticket
        entry_run = _resolve_run(store, run_id=entry.get("run_id") or run_id) or default_run
        entry_project = project or _project_from_evidence(store, entry_ticket, entry_run)
        resolved.append((index, entry, entry_ticket, entry_run, entry_project))
        if artifact_store is not None:
            if repo is None or entry_project is None:
                raise SessionCaptureError("artifact-backed capture requires confirmed project scope")
            durable_documents.append(
                durable_program_event(
                    project_id=artifact_store.project_id,
                    stable_key=f"capture:{capture_id}:{index}",
                    node_kind=entry["node_kind"],
                    capture_id=capture_id,
                    entry_index=index,
                    summary=entry["title"],
                    details=entry["body"],
                    occurred_at=occurred_at,
                    source=source,
                    provider=provider_key,
                    ticket_id=_ticket_id(entry_ticket),
                    run_id=_run_id(entry_run),
                    event_type=entry["event_type"],
                    risk_type=entry["risk_type"],
                    status=entry["status"],
                )
            )

    artifact_result = None
    if artifact_store is not None:
        if not artifact_device_id:
            raise SessionCaptureError("artifact-backed capture requires a writer device ID")
        writer_digest = hashlib.sha256(
            json.dumps(durable_documents, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()[:40]
        artifact_result = write_program_events(
            artifact_store,
            durable_documents,
            writer_event_id=f"program-capture:{writer_digest}",
            device_id=artifact_device_id,
            provider=provider_key,
        )
        assert project is not None and repo is not None
        ingest_project_program_events(store, project=project, repo_path=repo)
        for index, entry, _ticket, _run, _project in resolved:
            node = store.find_node(
                kind=entry["node_kind"],
                stable_key=f"capture:{capture_id}:{index}",
            )
            if node is None:
                raise SessionCaptureError(f"durable capture projection is missing entry {index}")
            counts[node["kind"]] += 1
            node_links = len(store.edges(src_id=node["id"])) + len(store.edges(dst_id=node["id"]))
            links += node_links
            created.append(
                {"id": node["id"], "kind": node["kind"], "title": node["title"], "links": node_links}
            )
    else:
        for index, entry, entry_ticket, entry_run, entry_project in resolved:
            node = store.upsert_node(
                kind=entry["node_kind"],
                stable_key=f"capture:{capture_id}:{index}",
                project_id=entry_project["id"] if entry_project else None,
                title=entry["title"],
                body=_node_body(
                    capture_id=capture_id,
                    index=index,
                    entry=entry,
                    repo=repo,
                    ticket=entry_ticket,
                    run=entry_run,
                    provider_key=provider_key,
                    context=context,
                    source=source,
                    occurred_at=occurred_at,
                ),
            )
            counts[node["kind"]] += 1
            linked = _link_capture_node(
                store,
                node=node,
                project=entry_project,
                ticket=entry_ticket,
                run=entry_run,
                capture_id=capture_id,
                entry=entry,
            )
            links += linked
            created.append(
                {
                    "id": node["id"],
                    "kind": node["kind"],
                    "title": node["title"],
                    "links": linked,
                }
            )

    result = {
        "capture_id": capture_id,
        "message": _message(
            created,
            repo,
            provider_key,
            durable=artifact_result is not None,
        ),
        "nodes": created,
        "counts": {key: value for key, value in counts.items() if value},
        "links": links,
        "provider": provider_key,
        "repo_path": str(repo) if repo else None,
    }
    if artifact_result is not None:
        result["artifact_commit"] = artifact_result.commit_id
        result["artifact_event_ids"] = list(artifact_result.event_ids)
        result["artifact_idempotent"] = artifact_result.idempotent
        result["durable_authority"] = "relay/artifacts"
    return result


def _normalize_entries(entries: list[dict[str, Any]] | None) -> list[dict[str, Any]]:
    if not entries:
        raise SessionCaptureError("entries is required")
    normalized: list[dict[str, Any]] = []
    for index, raw in enumerate(entries):
        if not isinstance(raw, dict):
            raise SessionCaptureError(f"entry {index} must be an object")
        raw_kind = _key(raw.get("kind") or raw.get("type") or "note")
        node_kind = _KIND_ALIASES.get(raw_kind)
        if node_kind is None:
            expected = ", ".join(sorted(_KIND_ALIASES))
            raise SessionCaptureError(f"entry {index} has unsupported kind {raw_kind!r}; expected one of {expected}")
        title = _first_text(raw, "title", "summary", "decision", "idea", "risk", "status", "note")
        if not title:
            title = _default_title(node_kind, raw_kind)
        body = _first_text(raw, "body", "details", "description", "note")
        normalized.append(
            {
                "node_kind": node_kind,
                "entry_kind": raw_kind,
                "title": title,
                "body": body,
                "event_type": _event_type(raw, raw_kind),
                "risk_type": _risk_type(raw, raw_kind),
                "status": _first_text(raw, "status", "state"),
                "ticket_id": _optional_text(raw.get("ticket_id")),
                "run_id": raw.get("run_id"),
                "raw": raw,
            }
        )
    return normalized


def _node_body(
    *,
    capture_id: str,
    index: int,
    entry: dict[str, Any],
    repo: Path | None,
    ticket: dict[str, Any] | None,
    run: dict[str, Any] | None,
    provider_key: str | None,
    context: str | None,
    source: str,
    occurred_at: float,
) -> dict[str, Any]:
    body = {
        "capture_id": capture_id,
        "capture_source": source,
        "entry_index": index,
        "entry_kind": entry["entry_kind"],
        "summary": entry["title"],
        "details": entry["body"],
        "provider_key": provider_key,
        "context": _optional_text(context),
        "occurred_at": occurred_at,
        "evidence": {
            "repo_path": str(repo) if repo else None,
            "ticket_id": _ticket_id(ticket),
            "run_id": _run_id(run),
        },
        "raw_entry": entry["raw"],
    }
    if entry["node_kind"] == NODE_PROGRAM_EVENT:
        body["event_type"] = entry["event_type"]
    if entry["node_kind"] == NODE_RISK:
        body["risk_type"] = entry["risk_type"]
    if entry["node_kind"] == NODE_STATUS:
        body["status"] = entry["status"] or entry["title"]
    return body


def _link_capture_node(
    store: GraphifyCoreStore,
    *,
    node: dict[str, Any],
    project: dict[str, Any] | None,
    ticket: dict[str, Any] | None,
    run: dict[str, Any] | None,
    capture_id: str,
    entry: dict[str, Any],
) -> int:
    links = 0
    body = {"source": "session_capture", "capture_id": capture_id}
    if project is not None:
        store.upsert_edge(src_id=node["id"], dst_id=project["id"], kind=EDGE_BELONGS_TO, body=body)
        store.upsert_edge(src_id=project["id"], dst_id=node["id"], kind=EDGE_CONTAINS, body=body)
        links += 2
    if ticket is not None:
        store.upsert_edge(src_id=node["id"], dst_id=ticket["id"], kind=EDGE_RELATED_TO, body=body)
        links += 1
        if node["kind"] == NODE_RISK and entry["risk_type"] == "blocker":
            store.upsert_edge(src_id=node["id"], dst_id=ticket["id"], kind=EDGE_BLOCKS, body=body)
            links += 1
    if run is not None:
        store.upsert_edge(src_id=node["id"], dst_id=run["id"], kind=EDGE_RELATED_TO, body=body)
        links += 1
    return links


def _resolve_or_create_project(store: GraphifyCoreStore, repo: Path | None) -> dict[str, Any] | None:
    if repo is None:
        return None
    stable_key = _project_key(repo)
    existing = store.find_node(kind=NODE_PROJECT, stable_key=stable_key)
    if existing is not None:
        return existing
    return store.upsert_node(
        kind=NODE_PROJECT,
        stable_key=stable_key,
        title=repo.name or str(repo),
        body={
            "repo_path": str(repo),
            "root_path": str(repo),
            "source": "session_capture",
        },
    )


def _resolve_ticket(
    store: GraphifyCoreStore,
    *,
    repo: Path | None,
    project: dict[str, Any] | None,
    ticket_id: str | None,
) -> dict[str, Any] | None:
    ticket_id = _optional_text(ticket_id)
    if not ticket_id:
        return None
    if project is not None:
        existing = store.find_node(kind=NODE_TICKET, stable_key=f"{project['stable_key']}:{ticket_id}")
        if existing is not None:
            return existing
        if repo is not None:
            ticket = _scan_ticket(repo, ticket_id)
            if ticket is not None:
                node = store.upsert_node(
                    kind=NODE_TICKET,
                    stable_key=f"{project['stable_key']}:{ticket_id}",
                    project_id=project["id"],
                    title=ticket["title"],
                    body={
                        "ticket_id": ticket["id"],
                        "state": ticket["status"],
                        "status": ticket["status"],
                        "priority": ticket["priority"],
                        "depends_on": ticket["depends_on"],
                        "run_id": ticket["run_id"],
                        "canceled": ticket["canceled"],
                        "source_path": str(ticket.get("_path", "")),
                        "markdown": ticket["body"],
                        "source": "session_capture",
                    },
                )
                store.upsert_edge(src_id=node["id"], dst_id=project["id"], kind=EDGE_BELONGS_TO)
                store.upsert_edge(src_id=project["id"], dst_id=node["id"], kind=EDGE_CONTAINS)
                return node
    matches = [
        node
        for node in store.nodes(kind=NODE_TICKET)
        if _ticket_id(node) == ticket_id
    ]
    return matches[0] if len(matches) == 1 else None


def _resolve_run(store: GraphifyCoreStore, *, run_id: int | str | None) -> dict[str, Any] | None:
    normalized = _normalize_run_id(run_id)
    if normalized is None:
        return None
    return store.find_node(kind=NODE_RUN, stable_key=f"run:{normalized}")


def _project_from_evidence(
    store: GraphifyCoreStore,
    ticket: dict[str, Any] | None,
    run: dict[str, Any] | None,
) -> dict[str, Any] | None:
    project_id = (ticket or {}).get("project_id") or (run or {}).get("project_id")
    if not project_id:
        return None
    project = store.get_node(str(project_id))
    return project if project and project["kind"] == NODE_PROJECT else None


def _scan_ticket(repo: Path, ticket_id: str) -> dict[str, Any] | None:
    for ticket in scan_repo(repo):
        if ticket["id"] == ticket_id:
            return ticket
    return None


def _resolve_repo_path(repo_path: str | Path | None) -> Path | None:
    text = _optional_text(repo_path)
    if not text:
        return None
    return Path(text).expanduser().resolve()


def _project_key(repo: Path) -> str:
    return f"repo:{repo}"


def _capture_id(
    capture_id: str | None,
    *,
    repo: Path | None,
    entries: list[dict[str, Any]],
    ticket_id: str | None,
    run_id: int | str | None,
    occurred_at: float,
) -> str:
    explicit = _optional_text(capture_id)
    if explicit:
        return explicit
    payload = json.dumps(
        {
            "repo": str(repo) if repo else None,
            "entries": [entry["raw"] for entry in entries],
            "ticket_id": ticket_id,
            "run_id": run_id,
            "occurred_at": occurred_at,
        },
        sort_keys=True,
        default=str,
    )
    digest = hashlib.sha1(payload.encode("utf-8")).hexdigest()[:10]
    return f"{int(occurred_at * 1000)}-{digest}"


def _message(
    nodes: list[dict[str, Any]],
    repo: Path | None,
    provider: str | None,
    *,
    durable: bool = False,
) -> str:
    repo_text = f" for {repo}" if repo else ""
    provider_text = f" ({provider})" if provider else ""
    destination = (
        "into Relay artifacts and refreshed Graphify Core"
        if durable
        else "into Graphify Core"
    )
    noun = "entry" if len(nodes) == 1 else "entries"
    return f"Captured {len(nodes)} session review {noun}{repo_text}{provider_text} {destination}."


def _event_type(raw: dict[str, Any], raw_kind: str) -> str:
    return _first_text(raw, "event_type", "event_kind") or _EVENT_TYPES.get(raw_kind) or "note"


def _risk_type(raw: dict[str, Any], raw_kind: str) -> str:
    if raw_kind in {"blocker", "blocked"}:
        return "blocker"
    return _first_text(raw, "risk_type", "risk_kind") or "risk"


def _default_title(node_kind: str, raw_kind: str) -> str:
    if node_kind == NODE_PROGRAM_EVENT:
        return _EVENT_TYPES.get(raw_kind, "note").replace("_", " ").title()
    return node_kind.replace("_", " ")


def _first_text(raw: dict[str, Any], *keys: str) -> str:
    for key in keys:
        text = _optional_text(raw.get(key))
        if text:
            return text
    return ""


def _optional_text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _normalize_provider(value: Any) -> str | None:
    text = _key(value)
    if not text:
        return None
    if "codex" in text:
        return "codex"
    if "claude" in text:
        return "claude"
    return text.replace("-", "_").replace(" ", "_")


def _normalize_run_id(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _ticket_id(ticket: dict[str, Any] | None) -> str | None:
    if ticket is None:
        return None
    return _optional_text(ticket.get("body", {}).get("ticket_id"))


def _run_id(run: dict[str, Any] | None) -> int | None:
    if run is None:
        return None
    return _normalize_run_id(run.get("body", {}).get("run_id"))


def _key(value: Any) -> str:
    return str(value or "").strip().lower().replace(" ", "_")
