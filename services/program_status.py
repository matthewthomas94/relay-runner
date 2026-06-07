"""Voice-friendly Program Manager status queries over Graphify Core."""

from __future__ import annotations

import time
from typing import Any

from graphify_core import (
    EDGE_BLOCKS,
    EDGE_EXECUTES,
    NODE_PROJECT,
    NODE_RUN,
    NODE_TICKET,
    GraphifyCoreStore,
)

QUERY_ACTIVE = "active_work"
QUERY_DISCOVERY = "discovery_work"
QUERY_READY = "ready_work"
QUERY_BLOCKED = "blocked_work"
QUERY_AWAITING_MERGE = "awaiting_merge"
QUERY_DONE = "done_work"
QUERY_STALE_RUNS = "stale_runs"
QUERY_SUMMARY = "summary"
QUERY_NEXT = "next"

PROGRAM_STATUS_QUERIES = (
    QUERY_ACTIVE,
    QUERY_DISCOVERY,
    QUERY_READY,
    QUERY_BLOCKED,
    QUERY_AWAITING_MERGE,
    QUERY_DONE,
    QUERY_STALE_RUNS,
    QUERY_SUMMARY,
    QUERY_NEXT,
)

QUERY_ALIASES = {
    "active": QUERY_ACTIVE,
    "active_agents": QUERY_ACTIVE,
    "active_runs": QUERY_ACTIVE,
    "active_work": QUERY_ACTIVE,
    "agents": QUERY_ACTIVE,
    "all_agents": QUERY_ACTIVE,
    "discovery": QUERY_DISCOVERY,
    "discovery_work": QUERY_DISCOVERY,
    "backlog": QUERY_DISCOVERY,
    "planned": QUERY_DISCOVERY,
    "ready": QUERY_READY,
    "ready_work": QUERY_READY,
    "ready_tickets": QUERY_READY,
    "blocked": QUERY_BLOCKED,
    "blocked_work": QUERY_BLOCKED,
    "awaiting": QUERY_AWAITING_MERGE,
    "awaiting_merge": QUERY_AWAITING_MERGE,
    "merge": QUERY_AWAITING_MERGE,
    "done": QUERY_DONE,
    "done_work": QUERY_DONE,
    "closed": QUERY_DONE,
    "completed": QUERY_DONE,
    "stale": QUERY_STALE_RUNS,
    "stale_runs": QUERY_STALE_RUNS,
    "stalled": QUERY_STALE_RUNS,
    "summary": QUERY_SUMMARY,
    "project_summary": QUERY_SUMMARY,
    "projects": QUERY_SUMMARY,
    "next": QUERY_NEXT,
    "attention": QUERY_NEXT,
    "look_at_next": QUERY_NEXT,
}

STALE_AFTER_SECONDS = 30 * 60


class ProgramStatusError(ValueError):
    pass


def normalize_program_status_query(query: str | None) -> str:
    key = _key(query or QUERY_SUMMARY)
    if key in QUERY_ALIASES:
        return QUERY_ALIASES[key]
    raise ProgramStatusError(
        "unknown program status query "
        f"{query!r}; expected one of {', '.join(PROGRAM_STATUS_QUERIES)}"
    )


def build_program_status(
    store: GraphifyCoreStore,
    *,
    query: str | None = None,
    provider: str | None = None,
    limit: int = 8,
    now: float | None = None,
    stale_after_seconds: int = STALE_AFTER_SECONDS,
) -> dict[str, Any]:
    query = normalize_program_status_query(query)
    provider_key = _provider_key(provider)
    limit = max(1, min(int(limit or 8), 20))
    now = time.time() if now is None else now
    ctx = _context(store)

    if not ctx["projects"]:
        return _response(
            query,
            provider_key,
            "No registered projects are indexed in Graphify Core. "
            "Activate or register a project, then refresh program status.",
            [],
            ctx,
        )

    if query == QUERY_ACTIVE:
        items = [_run_item(ctx, run, "active") for run in _active_runs(ctx, provider_key)]
        return _response(query, provider_key, _items_text("Active work", "run", items, ctx, limit), items[:limit], ctx)

    if query == QUERY_DISCOVERY:
        items = [_ticket_item(ctx, ticket, "discovery") for ticket in _discovery_tickets(ctx, provider_key)]
        return _response(query, provider_key, _items_text("Discovery", "ticket", items, ctx, limit), items[:limit], ctx)

    if query == QUERY_READY:
        items = [_ticket_item(ctx, ticket, "ready") for ticket in _ready_tickets(ctx, provider_key)]
        return _response(query, provider_key, _items_text("Ready work", "ticket", items, ctx, limit), items[:limit], ctx)

    if query == QUERY_BLOCKED:
        items = [_ticket_item(ctx, ticket, "blocked") for ticket in _blocked_tickets(ctx, provider_key)]
        return _response(query, provider_key, _items_text("Blocked work", "ticket", items, ctx, limit), items[:limit], ctx)

    if query == QUERY_AWAITING_MERGE:
        items = [
            _ticket_item(ctx, ticket, "awaiting merge")
            for ticket in _awaiting_merge_tickets(ctx, provider_key)
        ]
        return _response(
            query,
            provider_key,
            _items_text("Awaiting merge", "ticket", items, ctx, limit),
            items[:limit],
            ctx,
        )

    if query == QUERY_DONE:
        items = [_ticket_item(ctx, ticket, "done") for ticket in _done_tickets(ctx, provider_key)]
        return _response(query, provider_key, _items_text("Done work", "ticket", items, ctx, limit), items[:limit], ctx)

    if query == QUERY_STALE_RUNS:
        items = [
            _run_item(ctx, run, reason)
            for run, reason in _stale_runs(ctx, provider_key, now, stale_after_seconds)
        ]
        return _response(query, provider_key, _items_text("Stale runs", "run", items, ctx, limit), items[:limit], ctx)

    if query == QUERY_NEXT:
        items = _attention_items(ctx, provider_key, now, stale_after_seconds)
        return _response(query, provider_key, _items_text("Next attention", "item", items, ctx, limit), items[:limit], ctx)

    items = _summary_items(ctx, provider_key, now, stale_after_seconds)
    return _response(query, provider_key, _summary_text(items, provider_key), items[:limit], ctx)


def _context(store: GraphifyCoreStore) -> dict[str, Any]:
    projects = store.nodes(kind=NODE_PROJECT)
    tickets = store.nodes(kind=NODE_TICKET)
    runs = store.nodes(kind=NODE_RUN)
    tickets_by_id = {ticket["id"]: ticket for ticket in tickets}
    runs_by_id = {run["id"]: run for run in runs}
    projects_by_id = {project["id"]: project for project in projects}
    ticket_by_run: dict[str, dict[str, Any]] = {}
    runs_by_ticket: dict[str, list[dict[str, Any]]] = {ticket["id"]: [] for ticket in tickets}

    for edge in store.edges(kind=EDGE_EXECUTES):
        run = runs_by_id.get(edge["src_id"])
        ticket = tickets_by_id.get(edge["dst_id"])
        if run and ticket:
            ticket_by_run[run["id"]] = ticket
            runs_by_ticket.setdefault(ticket["id"], []).append(run)

    ticket_lookup = {
        (ticket.get("project_id"), _ticket_id(ticket)): ticket
        for ticket in tickets
        if _ticket_id(ticket)
    }
    for run in runs:
        if run["id"] in ticket_by_run:
            continue
        ticket = ticket_lookup.get((run.get("project_id"), _run_ticket_id(run)))
        if ticket:
            ticket_by_run[run["id"]] = ticket
            runs_by_ticket.setdefault(ticket["id"], []).append(run)

    blockers: dict[str, list[dict[str, Any]]] = {}
    for edge in store.edges(kind=EDGE_BLOCKS):
        blocker = tickets_by_id.get(edge["src_id"])
        blocked = tickets_by_id.get(edge["dst_id"])
        if blocker and blocked:
            blockers.setdefault(blocked["id"], []).append(blocker)

    for ticket_runs in runs_by_ticket.values():
        ticket_runs.sort(key=_run_sort_key, reverse=True)

    return {
        "projects": projects,
        "tickets": tickets,
        "runs": runs,
        "projects_by_id": projects_by_id,
        "ticket_by_run": ticket_by_run,
        "runs_by_ticket": runs_by_ticket,
        "blockers": blockers,
        "blocked_work": {ticket["id"] for ticket in store.blocked_work()},
        "awaiting_merge": {ticket["id"] for ticket in store.awaiting_merge()},
    }


def _active_runs(ctx: dict[str, Any], provider: str | None) -> list[dict[str, Any]]:
    return [
        run
        for run in sorted(ctx["runs"], key=_run_sort_key, reverse=True)
        if _run_state(run) == "active" and _run_matches_provider(run, provider)
    ]


def _blocked_tickets(ctx: dict[str, Any], provider: str | None) -> list[dict[str, Any]]:
    blocked_ids = set(ctx["blockers"]) | ctx["blocked_work"]
    return [
        ticket
        for ticket in sorted(ctx["tickets"], key=_ticket_sort_key)
        if (ticket["id"] in blocked_ids or _key(_ticket_state(ticket)) == "blocked")
        and _ticket_matches_provider(ctx, ticket, provider)
    ]


def _ready_tickets(ctx: dict[str, Any], provider: str | None) -> list[dict[str, Any]]:
    blocked_ids = set(ctx["blockers"]) | ctx["blocked_work"]
    awaiting_ids = {ticket["id"] for ticket in _awaiting_merge_tickets(ctx, provider)}
    return [
        ticket
        for ticket in sorted(ctx["tickets"], key=_ticket_sort_key)
        if _key(_ticket_state(ticket)) == "ready"
        and ticket["id"] not in blocked_ids
        and ticket["id"] not in awaiting_ids
        and _ticket_matches_provider(ctx, ticket, provider)
    ]


def _discovery_tickets(ctx: dict[str, Any], provider: str | None) -> list[dict[str, Any]]:
    blocked_ids = set(ctx["blockers"]) | ctx["blocked_work"]
    awaiting_ids = {ticket["id"] for ticket in _awaiting_merge_tickets(ctx, provider)}
    active_ticket_ids = {
        ticket["id"]
        for run in _active_runs(ctx, provider)
        if (ticket := ctx["ticket_by_run"].get(run["id"]))
    }
    return [
        ticket
        for ticket in sorted(ctx["tickets"], key=_ticket_sort_key)
        if _key(_ticket_state(ticket)) in {"backlog", "ready", "discovery"}
        and ticket["id"] not in blocked_ids
        and ticket["id"] not in awaiting_ids
        and ticket["id"] not in active_ticket_ids
        and _ticket_matches_provider(ctx, ticket, provider)
    ]


def _awaiting_merge_tickets(ctx: dict[str, Any], provider: str | None) -> list[dict[str, Any]]:
    ticket_ids = set(ctx["awaiting_merge"]) | {
        ticket["id"]
        for ticket in ctx["tickets"]
        if _key(_ticket_state(ticket)) in {"awaiting_merge", "awaitingmerge"}
        and _ticket_matches_provider(ctx, ticket, provider)
    }
    for run in ctx["runs"]:
        if _run_state(run) == "awaiting_merge" and _run_matches_provider(run, provider):
            ticket = ctx["ticket_by_run"].get(run["id"])
            if ticket:
                ticket_ids.add(ticket["id"])
    return [
        ticket
        for ticket in sorted(ctx["tickets"], key=_ticket_sort_key)
        if ticket["id"] in ticket_ids and _ticket_matches_provider(ctx, ticket, provider)
    ]


def _done_tickets(ctx: dict[str, Any], provider: str | None) -> list[dict[str, Any]]:
    return [
        ticket
        for ticket in sorted(ctx["tickets"], key=_ticket_sort_key)
        if _key(_ticket_state(ticket)) in {"done", "closed", "completed"}
        and _ticket_matches_provider(ctx, ticket, provider)
    ]


def _stale_runs(
    ctx: dict[str, Any],
    provider: str | None,
    now: float,
    stale_after_seconds: int,
) -> list[tuple[dict[str, Any], str]]:
    stale = []
    for run in sorted(ctx["runs"], key=_run_sort_key, reverse=True):
        if not _run_matches_provider(run, provider):
            continue
        state = _run_state(run)
        if state == "stalled":
            stale.append((run, "stalled"))
            continue
        if state != "active":
            continue
        body = run.get("body", {})
        last_activity = _number(body.get("activity_at")) or _number(body.get("started_at"))
        if last_activity and now - last_activity >= stale_after_seconds:
            stale.append((run, f"inactive {max(1, int((now - last_activity) // 60))}m"))
    return stale


def _attention_items(
    ctx: dict[str, Any],
    provider: str | None,
    now: float,
    stale_after_seconds: int,
) -> list[dict[str, Any]]:
    items = []
    for ticket in _awaiting_merge_tickets(ctx, provider):
        item = _ticket_item(ctx, ticket, "awaiting merge")
        item["attention"] = "awaiting merge"
        items.append(item)
    for ticket in _blocked_tickets(ctx, provider):
        item = _ticket_item(ctx, ticket, "blocked")
        item["attention"] = "blocked"
        items.append(item)
    for run, reason in _stale_runs(ctx, provider, now, stale_after_seconds):
        item = _run_item(ctx, run, reason)
        item["attention"] = "stale run"
        items.append(item)
    return items


def _summary_items(
    ctx: dict[str, Any],
    provider: str | None,
    now: float,
    stale_after_seconds: int,
) -> list[dict[str, Any]]:
    blocked = {ticket["id"] for ticket in _blocked_tickets(ctx, provider)}
    awaiting = {ticket["id"] for ticket in _awaiting_merge_tickets(ctx, provider)}
    stale = {run["id"] for run, _ in _stale_runs(ctx, provider, now, stale_after_seconds)}
    items = []
    for project in sorted(ctx["projects"], key=lambda p: (_project_name(p).lower(), _project_path(p))):
        tickets = [ticket for ticket in ctx["tickets"] if ticket.get("project_id") == project["id"]]
        runs = [run for run in ctx["runs"] if run.get("project_id") == project["id"]]
        if provider:
            tickets = [ticket for ticket in tickets if _ticket_matches_provider(ctx, ticket, provider)]
            runs = [run for run in runs if _run_matches_provider(run, provider)]
        items.append(
            {
                "project": _project(project),
                "open_tickets": sum(1 for ticket in tickets if _key(_ticket_state(ticket)) not in {"done", "canceled", "cancelled"}),
                "active_runs": sum(1 for run in runs if _run_state(run) == "active"),
                "blocked": sum(1 for ticket in tickets if ticket["id"] in blocked),
                "awaiting_merge": sum(1 for ticket in tickets if ticket["id"] in awaiting),
                "stale_runs": sum(1 for run in runs if run["id"] in stale),
                "providers": _project_provider_labels(project, runs, provider),
                "provider_health": _provider_health(project, provider),
            }
        )
    return items


def _run_item(ctx: dict[str, Any], run: dict[str, Any], status: str) -> dict[str, Any]:
    ticket = ctx["ticket_by_run"].get(run["id"])
    project = ctx["projects_by_id"].get((ticket or run).get("project_id"))
    body = run.get("body", {})
    return {
        "project": _project(project),
        "ticket_id": _run_ticket_id(run) or (ticket and _ticket_id(ticket)),
        "title": ticket.get("title") if ticket else run.get("title"),
        "status": status,
        "run_id": body.get("run_id"),
        "run_state": _run_state(run),
        "provider": _run_provider(run),
        "branch": body.get("branch"),
        "activity": body.get("activity"),
        "last_error": body.get("last_error"),
        "run_node_id": run["id"],
        "ticket_node_id": ticket["id"] if ticket else None,
    }


def _ticket_item(ctx: dict[str, Any], ticket: dict[str, Any], status: str) -> dict[str, Any]:
    latest_run = next(iter(ctx["runs_by_ticket"].get(ticket["id"], [])), None)
    blockers = [_ticket_id(blocker) for blocker in ctx["blockers"].get(ticket["id"], [])]
    return {
        "project": _project(ctx["projects_by_id"].get(ticket.get("project_id"))),
        "ticket_id": _ticket_id(ticket),
        "title": ticket.get("title"),
        "status": status,
        "ticket_state": _ticket_state(ticket),
        "run_id": latest_run.get("body", {}).get("run_id") if latest_run else None,
        "run_state": _run_state(latest_run) if latest_run else None,
        "provider": _run_provider(latest_run) if latest_run else None,
        "branch": latest_run.get("body", {}).get("branch") if latest_run else None,
        "activity": latest_run.get("body", {}).get("activity") if latest_run else None,
        "last_error": latest_run.get("body", {}).get("last_error") if latest_run else None,
        "blocked_by": [ticket_id for ticket_id in blockers if ticket_id],
        "ticket_node_id": ticket["id"],
    }


def _items_text(
    title: str,
    noun: str,
    items: list[dict[str, Any]],
    ctx: dict[str, Any],
    limit: int,
) -> str:
    if not items:
        empty = {
            QUERY_ACTIVE: "No active program runs",
            QUERY_DISCOVERY: "No discovery work",
            QUERY_READY: "No ready work",
            QUERY_BLOCKED: "No blocked work",
            QUERY_AWAITING_MERGE: "No tickets awaiting merge",
            QUERY_DONE: "No done work",
            QUERY_STALE_RUNS: "No stale or stalled runs",
            QUERY_NEXT: "No immediate program attention items",
        }.get(_key(title), f"No {title.lower()}")
        return f"{empty} across {_plural(len(ctx['projects']), 'indexed project')}."
    shown = items[:limit]
    lines = [f"{title}: {_plural(len(items), noun)} across {_plural(len(ctx['projects']), 'indexed project')}."]
    lines.extend(_item_line(item) for item in shown)
    if len(items) > len(shown):
        lines.append(f"- ... and {len(items) - len(shown)} more.")
    return "\n".join(lines)


def _summary_text(items: list[dict[str, Any]], provider: str | None) -> str:
    provider_text = f" for {_provider_label(provider)}" if provider else ""
    lines = [f"Program summary{provider_text}: {_plural(len(items), 'indexed project')}."]
    for item in items:
        project = item["project"]
        parts = [
            _plural(item["open_tickets"], "open ticket"),
            _plural(item["active_runs"], "active run"),
            f"{item['blocked']} blocked",
            f"{item['awaiting_merge']} awaiting merge",
            _plural(item["stale_runs"], "stale run"),
        ]
        providers = ", ".join(item["providers"]) or "none recorded"
        line = f"- {project['name']} ({project['path']}): {', '.join(parts)}. Providers: {providers}."
        if item["provider_health"]:
            line += " Provider health: " + "; ".join(item["provider_health"]) + "."
        lines.append(line)
    return "\n".join(lines)


def _item_line(item: dict[str, Any]) -> str:
    project = item["project"]
    subject = item.get("ticket_id") or "no ticket"
    if item.get("title"):
        subject += f" - {item['title']}"
    details = [str(item["attention"] if item.get("attention") else item.get("status"))]
    if item.get("run_id") is not None:
        details.append(f"run {item['run_id']}")
    if item.get("provider"):
        details.append(item["provider"])
    if item.get("blocked_by"):
        details.append("blocked by " + ", ".join(item["blocked_by"]))
    if item.get("activity"):
        details.append(str(item["activity"]))
    if item.get("last_error") and item.get("status") in {"stalled", "failed"}:
        details.append(str(item["last_error"]))
    return f"- {project['name']} ({project['path']}): {subject} ({'; '.join(details)})."


def _response(
    query: str,
    provider: str | None,
    message: str,
    items: list[dict[str, Any]],
    ctx: dict[str, Any],
) -> dict[str, Any]:
    return {
        "query": query,
        "provider": provider,
        "message": message,
        "items": items,
        "counts": {"projects": len(ctx["projects"]), "items": len(items)},
    }


def _ticket_matches_provider(ctx: dict[str, Any], ticket: dict[str, Any], provider: str | None) -> bool:
    if provider is None:
        return True
    return any(_run_matches_provider(run, provider) for run in ctx["runs_by_ticket"].get(ticket["id"], []))


def _run_matches_provider(run: dict[str, Any], provider: str | None) -> bool:
    return provider is None or _provider_key_from_run(run) == provider


def _run_state(run: dict[str, Any] | None) -> str:
    if run is None:
        return ""
    body = run.get("body", {})
    state = _key(body.get("program_state") or body.get("state") or body.get("raw_state"))
    if state in {"claimed", "running"}:
        return "active"
    if state in {"awaitingmerge", "awaiting_merge"}:
        return "awaiting_merge"
    return state


def _ticket_state(ticket: dict[str, Any]) -> str:
    body = ticket.get("body", {})
    return str(body.get("state") or body.get("status") or "")


def _run_provider(run: dict[str, Any] | None) -> str | None:
    provider = _provider_key_from_run(run)
    if not provider:
        return None
    model = run.get("body", {}).get("model_alias") if run else None
    return f"{_provider_label(provider)}/{model}" if model else _provider_label(provider)


def _provider_key_from_run(run: dict[str, Any] | None) -> str | None:
    if run is None:
        return None
    body = run.get("body", {})
    provider = body.get("provider")
    if isinstance(provider, dict) and _provider_key(provider.get("key")):
        return _provider_key(provider.get("key"))
    return _provider_key(body.get("provider_key"))


def _project_provider_labels(
    project: dict[str, Any],
    runs: list[dict[str, Any]],
    provider: str | None,
) -> list[str]:
    keys = set()
    raw = project.get("body", {}).get("providers")
    if isinstance(raw, dict):
        keys.update(_provider_key(key) for key in raw)
    keys.update(_provider_key_from_run(run) for run in runs)
    keys.discard(None)
    if provider:
        keys = {key for key in keys if key == provider}
    return [_provider_label(key) for key in sorted(keys)]


def _provider_health(project: dict[str, Any], provider: str | None) -> list[str]:
    raw = project.get("body", {}).get("providers")
    if not isinstance(raw, dict):
        return []
    issues = []
    for raw_key, metadata in sorted(raw.items()):
        key = _provider_key(raw_key)
        if provider and key != provider:
            continue
        if not isinstance(metadata, dict):
            continue
        health = metadata.get("health") or metadata.get("status") or metadata.get("config_status")
        if health and _key(health) not in {"ready", "ok", "unknown"}:
            issues.append(f"{_provider_label(key)} {health}")
        error = metadata.get("last_error") or metadata.get("error")
        if error:
            issues.append(f"{_provider_label(key)} {error}")
    return issues


def _project(project: dict[str, Any] | None) -> dict[str, str]:
    if project is None:
        return {"name": "Unknown project", "path": "unknown"}
    return {"name": _project_name(project), "path": _project_path(project)}


def _project_name(project: dict[str, Any]) -> str:
    body = project.get("body", {})
    return str(project.get("title") or body.get("display_name") or body.get("alias") or _project_path(project))


def _project_path(project: dict[str, Any]) -> str:
    body = project.get("body", {})
    return str(body.get("repo_path") or body.get("root_path") or body.get("project_id") or project.get("stable_key"))


def _ticket_id(ticket: dict[str, Any]) -> str:
    return str(ticket.get("body", {}).get("ticket_id") or "").strip()


def _run_ticket_id(run: dict[str, Any]) -> str:
    return str(run.get("body", {}).get("ticket_id") or "").strip()


def _ticket_sort_key(ticket: dict[str, Any]) -> tuple[str, str]:
    return (str(ticket.get("project_id") or ""), _ticket_id(ticket))


def _run_sort_key(run: dict[str, Any]) -> tuple[float, float]:
    body = run.get("body", {})
    return (_number(body.get("started_at")), _number(body.get("run_id")))


def _plural(count: int, noun: str) -> str:
    return f"{count} {noun if count == 1 else noun + 's'}"


def _provider_key(value: Any) -> str | None:
    key = _key(value)
    return key or None


def _provider_label(provider: str | None) -> str:
    labels = {"codex": "Codex", "claude": "Claude"}
    key = provider or "unknown"
    return labels.get(key, key.replace("_", " ").title())


def _key(value: Any) -> str:
    return str(value or "").strip().lower().replace("-", "_").replace(" ", "_")


def _number(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0
