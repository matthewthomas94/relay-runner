//! Voice-friendly Program Manager status queries over the program graph:
//! `services/program_status.py` (`build_program_status`,
//! `build_program_dashboard` and `program_context`) on
//! [`relay_store::graphify`].
//!
//! Every response is the Python module's dictionary, with its keys in the
//! same order and its message text word for word. The daemon's own wrapper
//! (the graph refresh before a status query and the "No registered projects
//! found at …" answer when the refresh found none) belongs with the HTTP
//! layer, as it does in `orchestrator.py`.

use std::collections::{HashMap, HashSet};
use std::os::unix::fs::MetadataExt;

use relay_intents::json::{py_strip, str_repr};
use relay_store::graphify::{
    EDGE_BLOCKS, EDGE_EXECUTES, GraphifyStore, NODE_PROJECT, NODE_RUN, NODE_TICKET,
};

use crate::{Dict, Error, Result, Value};

pub const QUERY_ACTIVE: &str = "active_work";
pub const QUERY_BACKLOG_LANE: &str = "backlog_lane";
pub const QUERY_READY_LANE: &str = "ready_lane";
pub const QUERY_IN_PROGRESS_LANE: &str = "in_progress_lane";
pub const QUERY_DONE_LANE: &str = "done_lane";
pub const QUERY_DISCOVERY: &str = "discovery_work";
pub const QUERY_READY: &str = "ready_work";
pub const QUERY_BLOCKED: &str = "blocked_work";
pub const QUERY_AWAITING_MERGE: &str = "awaiting_merge";
pub const QUERY_DONE: &str = "done_work";
pub const QUERY_STALE_RUNS: &str = "stale_runs";
pub const QUERY_SUMMARY: &str = "summary";
pub const QUERY_NEXT: &str = "next";

/// `PROGRAM_STATUS_QUERIES`, in the order the error message lists them.
pub const PROGRAM_STATUS_QUERIES: [&str; 13] = [
    QUERY_ACTIVE,
    QUERY_BACKLOG_LANE,
    QUERY_READY_LANE,
    QUERY_IN_PROGRESS_LANE,
    QUERY_DONE_LANE,
    QUERY_DISCOVERY,
    QUERY_READY,
    QUERY_BLOCKED,
    QUERY_AWAITING_MERGE,
    QUERY_DONE,
    QUERY_STALE_RUNS,
    QUERY_SUMMARY,
    QUERY_NEXT,
];

/// `QUERY_ALIASES`.
pub const QUERY_ALIASES: [(&str, &str); 40] = [
    ("active", QUERY_ACTIVE),
    ("active_agents", QUERY_ACTIVE),
    ("active_runs", QUERY_ACTIVE),
    ("active_work", QUERY_ACTIVE),
    ("agents", QUERY_ACTIVE),
    ("all_agents", QUERY_ACTIVE),
    ("backlog_lane", QUERY_BACKLOG_LANE),
    ("board_backlog", QUERY_BACKLOG_LANE),
    ("ready_lane", QUERY_READY_LANE),
    ("board_ready", QUERY_READY_LANE),
    ("in_progress", QUERY_IN_PROGRESS_LANE),
    ("in_progress_lane", QUERY_IN_PROGRESS_LANE),
    ("board_in_progress", QUERY_IN_PROGRESS_LANE),
    ("done_lane", QUERY_DONE_LANE),
    ("board_done", QUERY_DONE_LANE),
    ("discovery", QUERY_DISCOVERY),
    ("discovery_work", QUERY_DISCOVERY),
    ("planned", QUERY_DISCOVERY),
    ("backlog", QUERY_BACKLOG_LANE),
    ("ready", QUERY_READY),
    ("ready_work", QUERY_READY),
    ("ready_tickets", QUERY_READY),
    ("blocked", QUERY_BLOCKED),
    ("blocked_work", QUERY_BLOCKED),
    ("awaiting", QUERY_AWAITING_MERGE),
    ("awaiting_merge", QUERY_AWAITING_MERGE),
    ("merge", QUERY_AWAITING_MERGE),
    ("done", QUERY_DONE),
    ("done_work", QUERY_DONE),
    ("closed", QUERY_DONE),
    ("completed", QUERY_DONE),
    ("stale", QUERY_STALE_RUNS),
    ("stale_runs", QUERY_STALE_RUNS),
    ("stalled", QUERY_STALE_RUNS),
    ("summary", QUERY_SUMMARY),
    ("project_summary", QUERY_SUMMARY),
    ("projects", QUERY_SUMMARY),
    ("next", QUERY_NEXT),
    ("attention", QUERY_NEXT),
    ("look_at_next", QUERY_NEXT),
];

pub const STALE_AFTER_SECONDS: i64 = 30 * 60;

fn status_error(message: String) -> Error {
    Error::new("ProgramStatusError", message)
}

/// `normalize_program_status_query`: the canonical query for an alias.
pub fn normalize_program_status_query(query: Option<&str>) -> Result<&'static str> {
    let raw = query
        .filter(|query| !query.is_empty())
        .unwrap_or(QUERY_SUMMARY);
    let key = key_text(raw);
    QUERY_ALIASES
        .iter()
        .find(|(alias, _)| *alias == key)
        .map(|(_, canonical)| *canonical)
        .ok_or_else(|| {
            let shown = match query {
                Some(query) => str_repr(query),
                None => "None".to_string(),
            };
            status_error(format!(
                "unknown program status query {shown}; expected one of {}",
                PROGRAM_STATUS_QUERIES.join(", ")
            ))
        })
}

/// The graph-derived inputs of every Program view (`program_context`).
/// Builders only read it, so the HTTP layer may keep one for an unchanged
/// graph file and pass it to [`build_program_dashboard`] again.
#[derive(Clone, Debug, Default)]
pub struct ProgramContext {
    projects: Vec<Dict>,
    tickets: Vec<Dict>,
    runs: Vec<Dict>,
    projects_by_id: HashMap<String, usize>,
    ticket_lookup: HashMap<(Option<String>, String), usize>,
    /// Run node id → ticket index.
    ticket_by_run: HashMap<String, usize>,
    /// Ticket node id → run indexes, newest (or the ticket's linked run) first.
    runs_by_ticket: HashMap<String, Vec<usize>>,
    /// Blocked ticket node id → blocker ticket indexes.
    blockers: HashMap<String, Vec<usize>>,
    blocked_work: HashSet<String>,
    awaiting_merge: HashSet<String>,
}

/// `program_context(store, repo_paths)`.
pub fn program_context(
    store: &GraphifyStore,
    repo_paths: Option<&[String]>,
) -> Result<ProgramContext> {
    context(store, repo_paths)
}

/// `build_program_status`: one query's response. `limit` at or below zero
/// lists every item; `now` defaults to the current time.
pub fn build_program_status(
    store: &GraphifyStore,
    query: Option<&str>,
    provider: Option<&str>,
    limit: i64,
    now: Option<f64>,
    stale_after_seconds: i64,
) -> Result<Dict> {
    let query = normalize_program_status_query(query)?;
    let provider_key = provider_key_text(provider);
    let item_limit = item_limit(limit);
    let now = now.unwrap_or_else(relay_store::sql::now);
    let ctx = context(store, None)?;
    Ok(build_from_context(
        &ctx,
        query,
        provider_key.as_deref(),
        item_limit,
        now,
        stale_after_seconds,
    ))
}

/// `build_program_dashboard`: the summary and the board lanes. `context`
/// is a reusable [`program_context`] result for the same `repo_paths`.
pub fn build_program_dashboard(
    store: &GraphifyStore,
    provider: Option<&str>,
    repo_paths: Option<&[String]>,
    limit: i64,
    now: Option<f64>,
    stale_after_seconds: i64,
    context_in: Option<&ProgramContext>,
) -> Result<Dict> {
    let provider_key = provider_key_text(provider);
    let item_limit = item_limit(limit);
    let now = now.unwrap_or_else(relay_store::sql::now);
    let owned;
    let ctx = match context_in {
        Some(ctx) => ctx,
        None => {
            owned = context(store, repo_paths)?;
            &owned
        }
    };
    let build = |query| {
        Value::Dict(build_from_context(
            ctx,
            query,
            provider_key.as_deref(),
            item_limit,
            now,
            stale_after_seconds,
        ))
    };
    let mut dashboard = Dict::new();
    dashboard.insert("summary", build(QUERY_SUMMARY));
    dashboard.insert("backlog", build(QUERY_BACKLOG_LANE));
    dashboard.insert("ready", build(QUERY_READY_LANE));
    dashboard.insert("in_progress", build(QUERY_IN_PROGRESS_LANE));
    dashboard.insert("done", build(QUERY_DONE_LANE));
    dashboard.insert("awaiting_merge", build(QUERY_AWAITING_MERGE));
    Ok(dashboard)
}

/// `None if raw_limit <= 0 else max(1, min(raw_limit, 500))`.
fn item_limit(limit: i64) -> Option<usize> {
    (limit > 0).then(|| limit.clamp(1, 500) as usize)
}

fn build_from_context(
    ctx: &ProgramContext,
    query: &str,
    provider: Option<&str>,
    limit: Option<usize>,
    now: f64,
    stale: i64,
) -> Dict {
    if ctx.projects.is_empty() {
        return response(
            query,
            provider,
            "No registered projects are indexed in Graphify Core. \
             Activate or register a project, then refresh program status."
                .to_string(),
            Vec::new(),
            ctx,
        );
    }
    let tickets = |selected: Vec<usize>, status: &str| -> Vec<Dict> {
        selected
            .into_iter()
            .map(|ticket| ticket_item(ctx, ticket, status))
            .collect()
    };
    let (title, noun, items) = match query {
        QUERY_ACTIVE => (
            "Active work",
            "run",
            active_runs(ctx, provider)
                .into_iter()
                .map(|run| run_item(ctx, run, "active"))
                .collect(),
        ),
        QUERY_BACKLOG_LANE => (
            "Backlog",
            "ticket",
            tickets(board_lane_tickets(ctx, provider, "backlog"), "backlog"),
        ),
        QUERY_READY_LANE => (
            "Queued",
            "ticket",
            tickets(board_lane_tickets(ctx, provider, "ready"), "ready"),
        ),
        QUERY_IN_PROGRESS_LANE => (
            "In progress",
            "ticket",
            tickets(
                board_lane_tickets(ctx, provider, "in_progress"),
                "in progress",
            ),
        ),
        QUERY_DONE_LANE => (
            "Done",
            "ticket",
            tickets(board_lane_tickets(ctx, provider, "done"), "done"),
        ),
        QUERY_DISCOVERY => (
            "Discovery",
            "ticket",
            tickets(discovery_tickets(ctx, provider), "discovery"),
        ),
        QUERY_READY => (
            "Queued work",
            "ticket",
            tickets(ready_tickets(ctx, provider), "ready"),
        ),
        QUERY_BLOCKED => (
            "Blocked work",
            "ticket",
            tickets(blocked_tickets(ctx, provider), "blocked"),
        ),
        QUERY_AWAITING_MERGE => (
            "Awaiting review",
            "ticket",
            awaiting_merge_tickets(ctx, provider)
                .into_iter()
                .map(|ticket| awaiting_review_item(ctx, ticket))
                .collect(),
        ),
        QUERY_DONE => (
            "Done work",
            "ticket",
            tickets(done_tickets(ctx, provider), "done"),
        ),
        QUERY_STALE_RUNS => (
            "Stale runs",
            "run",
            stale_runs(ctx, provider, now, stale)
                .into_iter()
                .map(|(run, reason)| run_item(ctx, run, &reason))
                .collect(),
        ),
        QUERY_NEXT => (
            "Next attention",
            "item",
            attention_items(ctx, provider, now, stale),
        ),
        _ => {
            let items = summary_items(ctx, provider, now, stale);
            let message = summary_text(&items, provider);
            return response(query, provider, message, limit_items(items, limit), ctx);
        }
    };
    let message = items_text(title, noun, &items, ctx, limit);
    response(query, provider, message, limit_items(items, limit), ctx)
}

fn context(store: &GraphifyStore, repo_paths: Option<&[String]>) -> Result<ProgramContext> {
    store
        .with(|graph| {
            let mut projects = graph.nodes(Some(NODE_PROJECT), None)?;
            if let Some(repo_paths) = repo_paths {
                let allowed: HashSet<String> = repo_paths
                    .iter()
                    .filter(|path| !py_strip(path).is_empty())
                    .map(|path| relay_store::sql::resolve_path(path))
                    .collect();
                projects.retain(|project| {
                    allowed.contains(&relay_store::sql::resolve_path(&project_path(project)))
                });
            }
            let project_ids: HashSet<String> = projects.iter().map(node_id).collect();
            let in_projects = |node: &Dict| {
                node.get("project_id")
                    .and_then(Value::as_str)
                    .is_some_and(|id| project_ids.contains(id))
            };
            let mut tickets = graph.nodes(Some(NODE_TICKET), None)?;
            tickets.retain(in_projects);
            let mut runs = graph.nodes(Some(NODE_RUN), None)?;
            runs.retain(in_projects);
            let executes = graph.edges(Some(EDGE_EXECUTES), None, None)?;
            let blocks = graph.edges(Some(EDGE_BLOCKS), None, None)?;
            let blocked_work: HashSet<String> = graph
                .blocked_work(None, Some(tickets.clone()))?
                .iter()
                .map(node_id)
                .collect();
            let awaiting_merge: HashSet<String> = graph
                .awaiting_merge(None, Some(tickets.clone()))?
                .iter()
                .map(node_id)
                .collect();
            Ok(assemble(
                projects,
                tickets,
                runs,
                &executes,
                &blocks,
                blocked_work,
                awaiting_merge,
            ))
        })
        .map_err(Error::from)
}

fn assemble(
    projects: Vec<Dict>,
    tickets: Vec<Dict>,
    runs: Vec<Dict>,
    executes: &[Dict],
    blocks: &[Dict],
    blocked_work: HashSet<String>,
    awaiting_merge: HashSet<String>,
) -> ProgramContext {
    let index = |nodes: &[Dict]| -> HashMap<String, usize> {
        nodes
            .iter()
            .enumerate()
            .map(|(position, node)| (node_id(node), position))
            .collect()
    };
    let tickets_by_id = index(&tickets);
    let runs_by_id = index(&runs);
    let projects_by_id = index(&projects);
    let mut ticket_by_run: HashMap<String, usize> = HashMap::new();
    let mut runs_by_ticket: HashMap<String, Vec<usize>> = tickets
        .iter()
        .map(|ticket| (node_id(ticket), Vec::new()))
        .collect();
    for edge in executes {
        let (Some(&run), Some(&ticket)) = (
            runs_by_id.get(edge_end(edge, "src_id")),
            tickets_by_id.get(edge_end(edge, "dst_id")),
        ) else {
            continue;
        };
        ticket_by_run.insert(node_id(&runs[run]), ticket);
        runs_by_ticket
            .entry(node_id(&tickets[ticket]))
            .or_default()
            .push(run);
    }
    let mut ticket_lookup = HashMap::new();
    for (position, ticket) in tickets.iter().enumerate() {
        let id = ticket_id(ticket);
        if !id.is_empty() {
            ticket_lookup.insert((project_of(ticket), id), position);
        }
    }
    for (position, run) in runs.iter().enumerate() {
        if ticket_by_run.contains_key(&node_id(run)) {
            continue;
        }
        if let Some(&ticket) = ticket_lookup.get(&(project_of(run), run_ticket_id(run))) {
            ticket_by_run.insert(node_id(run), ticket);
            runs_by_ticket
                .entry(node_id(&tickets[ticket]))
                .or_default()
                .push(position);
        }
    }
    let mut blockers: HashMap<String, Vec<usize>> = HashMap::new();
    for edge in blocks {
        if let (Some(&blocker), Some(&blocked)) = (
            tickets_by_id.get(edge_end(edge, "src_id")),
            tickets_by_id.get(edge_end(edge, "dst_id")),
        ) {
            blockers
                .entry(node_id(&tickets[blocked]))
                .or_default()
                .push(blocker);
        }
    }
    for (ticket_node, ticket_runs) in runs_by_ticket.iter_mut() {
        sort_runs_newest_first(&runs, ticket_runs);
        let linked = tickets_by_id
            .get(ticket_node)
            .map(|&ticket| body(&tickets[ticket], "run_id"))
            .unwrap_or(&Value::Null);
        if matches!(linked, Value::Null) {
            continue;
        }
        let linked = linked.py_str();
        if let Some(position) = ticket_runs
            .iter()
            .position(|&run| body(&runs[run], "run_id").py_str() == linked)
        {
            let run = ticket_runs.remove(position);
            ticket_runs.insert(0, run);
        }
    }
    let ticket_ids: HashSet<String> = tickets_by_id.keys().cloned().collect();
    ProgramContext {
        blocked_work: blocked_work.intersection(&ticket_ids).cloned().collect(),
        awaiting_merge: awaiting_merge.intersection(&ticket_ids).cloned().collect(),
        projects,
        tickets,
        runs,
        projects_by_id,
        ticket_lookup,
        ticket_by_run,
        runs_by_ticket,
        blockers,
    }
}

// ---- node fields -----------------------------------------------------------

fn node_id(node: &Dict) -> String {
    node.get("id").map(Value::py_str).unwrap_or_default()
}

fn edge_end<'a>(edge: &'a Dict, side: &str) -> &'a str {
    edge.get(side).and_then(Value::as_str).unwrap_or("")
}

fn project_of(node: &Dict) -> Option<String> {
    node.get("project_id")
        .and_then(Value::as_str)
        .map(str::to_string)
}

/// `node.get("body", {}).get(key)`.
fn body<'a>(node: &'a Dict, key: &str) -> &'a Value {
    node.get("body")
        .and_then(Value::as_dict)
        .and_then(|body| body.get(key))
        .unwrap_or(&Value::Null)
}

fn node_field<'a>(node: &'a Dict, key: &str) -> &'a Value {
    node.get(key).unwrap_or(&Value::Null)
}

/// The first truthy value, as `a or b or c`.
fn first_truthy<'a>(values: &[&'a Value]) -> &'a Value {
    values
        .iter()
        .copied()
        .find(|value| value.truthy())
        .unwrap_or(&Value::Null)
}

/// `str(value or "")`.
fn or_empty(value: &Value) -> String {
    if value.truthy() {
        value.py_str()
    } else {
        String::new()
    }
}

/// `_key`: `str(value or "").strip().lower()` with `-` and spaces as `_`.
fn key(value: &Value) -> String {
    key_text(&or_empty(value))
}

fn key_text(text: &str) -> String {
    py_strip(text).to_lowercase().replace(['-', ' '], "_")
}

/// `_number`: `float(value)`, `0.0` where Python raises.
fn number(value: &Value) -> f64 {
    value.py_float().unwrap_or(0.0)
}

fn provider_key_text(provider: Option<&str>) -> Option<String> {
    let key = key_text(provider.unwrap_or(""));
    (!key.is_empty()).then_some(key)
}

/// `_provider_key`.
fn provider_key(value: &Value) -> Option<String> {
    let key = key(value);
    (!key.is_empty()).then_some(key)
}

fn ticket_state(ticket: &Dict) -> String {
    or_empty(first_truthy(&[
        body(ticket, "state"),
        body(ticket, "status"),
    ]))
}

fn ticket_id(ticket: &Dict) -> String {
    py_strip(&or_empty(body(ticket, "ticket_id"))).to_string()
}

fn run_ticket_id(run: &Dict) -> String {
    py_strip(&or_empty(body(run, "ticket_id"))).to_string()
}

fn run_state(run: Option<&Dict>) -> String {
    let Some(run) = run else {
        return String::new();
    };
    let state = key(first_truthy(&[
        body(run, "program_state"),
        body(run, "state"),
        body(run, "raw_state"),
    ]));
    match state.as_str() {
        "claimed" | "running" => "active".to_string(),
        "reviewing" => "reviewing".to_string(),
        "awaitingreview" | "awaiting_review" => "awaiting_review".to_string(),
        "mergeconflict" | "merge_conflict" => "merge_conflict".to_string(),
        "awaitingmerge" | "awaiting_merge" => "awaiting_merge".to_string(),
        _ => state,
    }
}

fn ticket_is_terminal(ticket: Option<&Dict>) -> bool {
    ticket.is_some_and(|ticket| {
        matches!(
            key_text(&ticket_state(ticket)).as_str(),
            "done" | "closed" | "completed" | "awaitingmerge" | "awaiting_merge"
        )
    })
}

fn ticket_priority(ticket: &Dict) -> Value {
    let priority = body(ticket, "priority");
    if priority.truthy() {
        Value::Str(py_strip(&priority.py_str()).to_string())
    } else {
        Value::Null
    }
}

fn ticket_depends_on(ticket: &Dict) -> Vec<String> {
    match body(ticket, "depends_on") {
        Value::Str(text) if !text.is_empty() => vec![text.clone()],
        Value::List(items) => items
            .iter()
            .map(Value::py_str)
            .filter(|item| !item.is_empty())
            .collect(),
        _ => Vec::new(),
    }
}

fn first_present_body(run: Option<&Dict>, ticket: &Dict, field: &str) -> Value {
    if let Some(run) = run {
        let value = body(run, field);
        if value.truthy() {
            return value.clone();
        }
    }
    body(ticket, field).clone()
}

fn ticket_worker_sizing_error(ticket: &Dict) -> Value {
    if key_text(&ticket_state(ticket)) != "ready" {
        return Value::Null;
    }
    let missing: Vec<&str> = [
        "worker_model",
        "worker_effort",
        "worker_sizing_rationale",
        "worker_provider_notes",
    ]
    .into_iter()
    .filter(|field| py_strip(&or_empty(body(ticket, field))).is_empty())
    .collect();
    if missing.is_empty() {
        return Value::Null;
    }
    Value::Str(format!(
        "Missing worker sizing metadata: {}",
        missing.join(", ")
    ))
}

fn provider_key_from_run(run: Option<&Dict>) -> Option<String> {
    let run = run?;
    if let Value::Dict(provider) = body(run, "provider")
        && let Some(key) = provider_key(provider.get("key").unwrap_or(&Value::Null))
    {
        return Some(key);
    }
    provider_key(body(run, "provider_key"))
}

fn run_provider(run: Option<&Dict>) -> Value {
    let Some(provider) = provider_key_from_run(run) else {
        return Value::Null;
    };
    let model = run.map_or(&Value::Null, |run| body(run, "model_alias"));
    if model.truthy() {
        Value::Str(format!("{}/{}", provider_label(&provider), model.py_str()))
    } else {
        Value::Str(provider_label(&provider))
    }
}

/// `_provider_label`: Codex, Claude, or the key in title case.
fn provider_label(provider: &str) -> String {
    match provider {
        "codex" => "Codex".to_string(),
        "claude" => "Claude".to_string(),
        "" => "Unknown".to_string(),
        other => title_case(&other.replace('_', " ")),
    }
}

/// Python's `str.title()`.
fn title_case(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut previous_cased = false;
    for character in text.chars() {
        if previous_cased {
            out.extend(character.to_lowercase());
        } else {
            out.extend(character.to_uppercase());
        }
        previous_cased = character.is_lowercase() || character.is_uppercase();
    }
    out
}

fn project_name(project: &Dict) -> String {
    let value = first_truthy(&[
        node_field(project, "title"),
        body(project, "display_name"),
        body(project, "alias"),
    ]);
    if value.truthy() {
        value.py_str()
    } else {
        project_path(project)
    }
}

fn project_path(project: &Dict) -> String {
    let value = first_truthy(&[
        body(project, "repo_path"),
        body(project, "root_path"),
        body(project, "project_id"),
    ]);
    if value.truthy() {
        value.py_str()
    } else {
        node_field(project, "stable_key").py_str()
    }
}

fn project_value(project: Option<&Dict>) -> Value {
    let mut value = Dict::new();
    match project {
        None => {
            value.insert("name", "Unknown project");
            value.insert("path", "unknown");
        }
        Some(project) => {
            value.insert("name", project_name(project));
            value.insert("path", project_path(project));
        }
    }
    Value::Dict(value)
}

fn ticket_modified_at(ticket: &Dict) -> Value {
    let source = py_strip(&or_empty(body(ticket, "source_path"))).to_string();
    if source.is_empty() {
        return Value::Null;
    }
    match std::fs::metadata(&source) {
        // `st_mtime` is `sec + nsec * 1e-9`, as CPython computes it.
        Ok(metadata) => Value::Float(metadata.mtime() as f64 + metadata.mtime_nsec() as f64 * 1e-9),
        Err(_) => Value::Null,
    }
}

// ---- selections --------------------------------------------------------------

fn sort_runs_newest_first(runs: &[Dict], selected: &mut [usize]) {
    let sort_key = |run: &Dict| (number(body(run, "started_at")), number(body(run, "run_id")));
    selected.sort_by(|&a, &b| {
        sort_key(&runs[b])
            .partial_cmp(&sort_key(&runs[a]))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
}

fn tickets_sorted(ctx: &ProgramContext) -> Vec<usize> {
    let sort_key = |ticket: &Dict| {
        (
            or_empty(node_field(ticket, "project_id")),
            ticket_id(ticket),
        )
    };
    let mut order: Vec<usize> = (0..ctx.tickets.len()).collect();
    order.sort_by_key(|&ticket| sort_key(&ctx.tickets[ticket]));
    order
}

fn latest_run(ctx: &ProgramContext, ticket: usize) -> Option<&Dict> {
    ctx.runs_by_ticket
        .get(&node_id(&ctx.tickets[ticket]))
        .and_then(|runs| runs.first())
        .map(|&run| &ctx.runs[run])
}

fn ticket_of_run(ctx: &ProgramContext, run: usize) -> Option<usize> {
    ctx.ticket_by_run.get(&node_id(&ctx.runs[run])).copied()
}

fn run_matches_provider(run: &Dict, provider: Option<&str>) -> bool {
    provider.is_none() || provider_key_from_run(Some(run)).as_deref() == provider
}

fn ticket_matches_provider(ctx: &ProgramContext, ticket: usize, provider: Option<&str>) -> bool {
    if provider.is_none() {
        return true;
    }
    ctx.runs_by_ticket
        .get(&node_id(&ctx.tickets[ticket]))
        .is_some_and(|runs| {
            runs.iter()
                .any(|&run| run_matches_provider(&ctx.runs[run], provider))
        })
}

fn run_is_active(ctx: &ProgramContext, run: usize) -> bool {
    matches!(
        run_state(Some(&ctx.runs[run])).as_str(),
        "active" | "reviewing"
    ) && !ticket_is_terminal(ticket_of_run(ctx, run).map(|ticket| &ctx.tickets[ticket]))
}

fn active_runs(ctx: &ProgramContext, provider: Option<&str>) -> Vec<usize> {
    let mut order: Vec<usize> = (0..ctx.runs.len()).collect();
    sort_runs_newest_first(&ctx.runs, &mut order);
    order
        .into_iter()
        .filter(|&run| run_is_active(ctx, run) && run_matches_provider(&ctx.runs[run], provider))
        .collect()
}

fn project_board_state(ctx: &ProgramContext, ticket: usize) -> &'static str {
    let state = key_text(&ticket_state(&ctx.tickets[ticket]));
    if matches!(
        state.as_str(),
        "done" | "closed" | "completed" | "canceled" | "cancelled"
    ) {
        return "done";
    }
    match run_state(latest_run(ctx, ticket)).as_str() {
        "active"
        | "reviewing"
        | "stalled"
        | "awaiting_merge"
        | "awaiting_review"
        | "merge_conflict"
        | "integration_blocked"
        | "verification_blocked" => {
            return "in_progress";
        }
        _ => {}
    }
    match state.as_str() {
        "inprogress" | "in_progress" | "verification_blocked" => "in_progress",
        "ready" | "awaitingmerge" | "awaiting_merge" => "ready",
        _ => "backlog",
    }
}

fn materialized_false(ticket: &Dict) -> bool {
    matches!(body(ticket, "materialized"), Value::Bool(false))
}

fn board_lane_tickets(ctx: &ProgramContext, provider: Option<&str>, lane: &str) -> Vec<usize> {
    tickets_sorted(ctx)
        .into_iter()
        .filter(|&ticket| {
            project_board_state(ctx, ticket) == lane
                && !materialized_false(&ctx.tickets[ticket])
                && ticket_matches_provider(ctx, ticket, provider)
        })
        .collect()
}

fn blocked_ids(ctx: &ProgramContext) -> HashSet<String> {
    ctx.blockers
        .keys()
        .cloned()
        .chain(ctx.blocked_work.iter().cloned())
        .collect()
}

fn unsatisfied_dependencies(ctx: &ProgramContext, ticket: usize) -> Vec<String> {
    let node = &ctx.tickets[ticket];
    let project = project_of(node);
    ticket_depends_on(node)
        .into_iter()
        .filter(|dependency| {
            match ctx
                .ticket_lookup
                .get(&(project.clone(), dependency.clone()))
            {
                None => true,
                Some(&dep) => !matches!(
                    key_text(&ticket_state(&ctx.tickets[dep])).as_str(),
                    "done" | "closed" | "completed"
                ),
            }
        })
        .collect()
}

fn blocked_tickets(ctx: &ProgramContext, provider: Option<&str>) -> Vec<usize> {
    let blocked = blocked_ids(ctx);
    tickets_sorted(ctx)
        .into_iter()
        .filter(|&ticket| {
            let node = &ctx.tickets[ticket];
            (blocked.contains(&node_id(node))
                || !unsatisfied_dependencies(ctx, ticket).is_empty()
                || matches!(
                    key_text(&ticket_state(node)).as_str(),
                    "blocked" | "verification_blocked"
                ))
                && ticket_matches_provider(ctx, ticket, provider)
        })
        .collect()
}

fn awaiting_merge_tickets(ctx: &ProgramContext, provider: Option<&str>) -> Vec<usize> {
    let mut ids: HashSet<String> = ctx.awaiting_merge.clone();
    for (ticket, node) in ctx.tickets.iter().enumerate() {
        if matches!(
            key_text(&ticket_state(node)).as_str(),
            "awaiting_merge" | "awaitingmerge"
        ) && ticket_matches_provider(ctx, ticket, provider)
        {
            ids.insert(node_id(node));
        }
    }
    for (run, node) in ctx.runs.iter().enumerate() {
        if matches!(
            run_state(Some(node)).as_str(),
            "awaiting_merge" | "awaiting_review" | "merge_conflict" | "integration_blocked"
        ) && run_matches_provider(node, provider)
            && let Some(ticket) = ticket_of_run(ctx, run)
        {
            ids.insert(node_id(&ctx.tickets[ticket]));
        }
    }
    tickets_sorted(ctx)
        .into_iter()
        .filter(|&ticket| {
            ids.contains(&node_id(&ctx.tickets[ticket]))
                && ticket_matches_provider(ctx, ticket, provider)
        })
        .collect()
}

fn ticket_ids(ctx: &ProgramContext, tickets: &[usize]) -> HashSet<String> {
    tickets
        .iter()
        .map(|&ticket| node_id(&ctx.tickets[ticket]))
        .collect()
}

fn ready_tickets(ctx: &ProgramContext, provider: Option<&str>) -> Vec<usize> {
    let awaiting = ticket_ids(ctx, &awaiting_merge_tickets(ctx, provider));
    tickets_sorted(ctx)
        .into_iter()
        .filter(|&ticket| {
            let node = &ctx.tickets[ticket];
            key_text(&ticket_state(node)) == "ready"
                && !awaiting.contains(&node_id(node))
                && ticket_matches_provider(ctx, ticket, provider)
        })
        .collect()
}

fn discovery_tickets(ctx: &ProgramContext, provider: Option<&str>) -> Vec<usize> {
    let blocked = blocked_ids(ctx);
    let awaiting = ticket_ids(ctx, &awaiting_merge_tickets(ctx, provider));
    let active: HashSet<String> = active_runs(ctx, provider)
        .into_iter()
        .filter_map(|run| ticket_of_run(ctx, run))
        .map(|ticket| node_id(&ctx.tickets[ticket]))
        .collect();
    tickets_sorted(ctx)
        .into_iter()
        .filter(|&ticket| {
            let node = &ctx.tickets[ticket];
            let id = node_id(node);
            matches!(
                key_text(&ticket_state(node)).as_str(),
                "backlog" | "ready" | "discovery"
            ) && !blocked.contains(&id)
                && !awaiting.contains(&id)
                && !active.contains(&id)
                && ticket_matches_provider(ctx, ticket, provider)
        })
        .collect()
}

fn done_tickets(ctx: &ProgramContext, provider: Option<&str>) -> Vec<usize> {
    tickets_sorted(ctx)
        .into_iter()
        .filter(|&ticket| {
            matches!(
                key_text(&ticket_state(&ctx.tickets[ticket])).as_str(),
                "done" | "closed" | "completed"
            ) && ticket_matches_provider(ctx, ticket, provider)
        })
        .collect()
}

fn stale_runs(
    ctx: &ProgramContext,
    provider: Option<&str>,
    now: f64,
    stale_after_seconds: i64,
) -> Vec<(usize, String)> {
    let mut order: Vec<usize> = (0..ctx.runs.len()).collect();
    sort_runs_newest_first(&ctx.runs, &mut order);
    let mut stale = Vec::new();
    for run in order {
        let node = &ctx.runs[run];
        if !run_matches_provider(node, provider) {
            continue;
        }
        if ticket_is_terminal(ticket_of_run(ctx, run).map(|ticket| &ctx.tickets[ticket])) {
            continue;
        }
        if run_state(Some(node)) == "stalled" {
            stale.push((run, "stalled".to_string()));
            continue;
        }
        if !run_is_active(ctx, run) {
            continue;
        }
        let mut last_activity = number(body(node, "activity_at"));
        if last_activity == 0.0 {
            last_activity = number(body(node, "started_at"));
        }
        if last_activity != 0.0 && now - last_activity >= stale_after_seconds as f64 {
            let minutes = ((now - last_activity) / 60.0).floor() as i64;
            stale.push((run, format!("inactive {}m", minutes.max(1))));
        }
    }
    stale
}

fn attention_items(
    ctx: &ProgramContext,
    provider: Option<&str>,
    now: f64,
    stale: i64,
) -> Vec<Dict> {
    let mut items = Vec::new();
    for ticket in awaiting_merge_tickets(ctx, provider) {
        let mut item = awaiting_review_item(ctx, ticket);
        let status = item.get("status").cloned().unwrap_or(Value::Null);
        item.insert("attention", status);
        items.push(item);
    }
    for ticket in blocked_tickets(ctx, provider) {
        let mut item = ticket_item(ctx, ticket, "blocked");
        item.insert("attention", "blocked");
        items.push(item);
    }
    for (run, reason) in stale_runs(ctx, provider, now, stale) {
        let mut item = run_item(ctx, run, &reason);
        item.insert("attention", "stale run");
        items.push(item);
    }
    items
}

fn summary_items(ctx: &ProgramContext, provider: Option<&str>, now: f64, stale: i64) -> Vec<Dict> {
    let blocked = ticket_ids(ctx, &blocked_tickets(ctx, provider));
    let awaiting = ticket_ids(ctx, &awaiting_merge_tickets(ctx, provider));
    let stale_ids: HashSet<String> = stale_runs(ctx, provider, now, stale)
        .into_iter()
        .map(|(run, _)| node_id(&ctx.runs[run]))
        .collect();
    let mut projects: Vec<&Dict> = ctx.projects.iter().collect();
    projects.sort_by_key(|project| (project_name(project).to_lowercase(), project_path(project)));
    let mut items = Vec::new();
    for project in projects {
        let id = node_id(project);
        let belongs =
            |node: &Dict| node.get("project_id").and_then(Value::as_str) == Some(id.as_str());
        let mut tickets: Vec<usize> = (0..ctx.tickets.len())
            .filter(|&ticket| belongs(&ctx.tickets[ticket]))
            .collect();
        let mut runs: Vec<usize> = (0..ctx.runs.len())
            .filter(|&run| belongs(&ctx.runs[run]))
            .collect();
        if provider.is_some() {
            tickets.retain(|&ticket| ticket_matches_provider(ctx, ticket, provider));
            runs.retain(|&run| run_matches_provider(&ctx.runs[run], provider));
        }
        let count =
            |iterator: &mut dyn Iterator<Item = bool>| iterator.filter(|hit| *hit).count() as i64;
        let mut item = Dict::new();
        item.insert("project", project_value(Some(project)));
        item.insert(
            "open_tickets",
            count(&mut tickets.iter().map(|&ticket| {
                !matches!(
                    key_text(&ticket_state(&ctx.tickets[ticket])).as_str(),
                    "done" | "canceled" | "cancelled"
                )
            })),
        );
        item.insert(
            "active_runs",
            count(&mut runs.iter().map(|&run| run_is_active(ctx, run))),
        );
        item.insert(
            "blocked",
            count(
                &mut tickets
                    .iter()
                    .map(|&ticket| blocked.contains(&node_id(&ctx.tickets[ticket]))),
            ),
        );
        item.insert(
            "awaiting_merge",
            count(
                &mut tickets
                    .iter()
                    .map(|&ticket| awaiting.contains(&node_id(&ctx.tickets[ticket]))),
            ),
        );
        item.insert(
            "stale_runs",
            count(
                &mut runs
                    .iter()
                    .map(|&run| stale_ids.contains(&node_id(&ctx.runs[run]))),
            ),
        );
        for (field, value) in project_board_counts(ctx, &tickets) {
            item.insert(field, value);
        }
        let run_nodes: Vec<&Dict> = runs.iter().map(|&run| &ctx.runs[run]).collect();
        item.insert(
            "providers",
            strings(project_provider_labels(project, &run_nodes, provider)),
        );
        item.insert(
            "provider_health",
            strings(provider_health(project, provider)),
        );
        items.push(item);
    }
    items
}

fn project_board_counts(ctx: &ProgramContext, tickets: &[usize]) -> [(&'static str, i64); 4] {
    let mut counts = [
        ("backlog_tickets", 0),
        ("ready_tickets", 0),
        ("in_progress_tickets", 0),
        ("done_tickets", 0),
    ];
    for &ticket in tickets {
        if materialized_false(&ctx.tickets[ticket]) {
            continue;
        }
        let slot = match project_board_state(ctx, ticket) {
            "backlog" => 0,
            "ready" => 1,
            "in_progress" => 2,
            _ => 3,
        };
        counts[slot].1 += 1;
    }
    counts
}

fn project_provider_labels(project: &Dict, runs: &[&Dict], provider: Option<&str>) -> Vec<String> {
    let mut keys: Vec<String> = Vec::new();
    if let Value::Dict(raw) = body(project, "providers") {
        keys.extend(
            raw.iter()
                .filter_map(|(key, _)| provider_key(&Value::Str(key.to_string()))),
        );
    }
    keys.extend(
        runs.iter()
            .filter_map(|run| provider_key_from_run(Some(run))),
    );
    if let Some(provider) = provider {
        keys.retain(|key| key == provider);
    }
    keys.sort();
    keys.dedup();
    keys.iter().map(|key| provider_label(key)).collect()
}

fn provider_health(project: &Dict, provider: Option<&str>) -> Vec<String> {
    let Value::Dict(raw) = body(project, "providers") else {
        return Vec::new();
    };
    let mut entries: Vec<(&str, &Value)> = raw.iter().collect();
    entries.sort_by(|a, b| a.0.cmp(b.0));
    let mut issues = Vec::new();
    for (raw_key, metadata) in entries {
        let entry_key = provider_key(&Value::Str(raw_key.to_string()));
        if provider.is_some() && entry_key.as_deref() != provider {
            continue;
        }
        let Value::Dict(metadata) = metadata else {
            continue;
        };
        let label = provider_label(entry_key.as_deref().unwrap_or(""));
        let field = |name: &str| metadata.get(name).unwrap_or(&Value::Null);
        let health = first_truthy(&[field("health"), field("status"), field("config_status")]);
        if health.truthy() && !matches!(key(health).as_str(), "ready" | "ok" | "unknown") {
            issues.push(format!("{label} {}", health.py_str()));
        }
        let error = first_truthy(&[field("last_error"), field("error")]);
        if error.truthy() {
            issues.push(format!("{label} {}", error.py_str()));
        }
    }
    issues
}

// ---- items and text ------------------------------------------------------------

fn strings(values: Vec<String>) -> Value {
    Value::List(values.into_iter().map(Value::Str).collect())
}

fn run_item(ctx: &ProgramContext, run: usize, status: &str) -> Dict {
    let node = &ctx.runs[run];
    let ticket = ticket_of_run(ctx, run).map(|ticket| &ctx.tickets[ticket]);
    let project_id = node_field(ticket.unwrap_or(node), "project_id");
    let project = project_id
        .as_str()
        .and_then(|id| ctx.projects_by_id.get(id))
        .map(|&project| &ctx.projects[project]);
    let field = |name: &str| body(node, name).clone();
    let state = run_state(Some(node));
    let run_ticket = run_ticket_id(node);
    let mut item = Dict::new();
    item.insert("project", project_value(project));
    item.insert(
        "ticket_id",
        if !run_ticket.is_empty() {
            Value::Str(run_ticket)
        } else {
            ticket.map_or(Value::Null, |ticket| Value::Str(ticket_id(ticket)))
        },
    );
    item.insert("title", node_field(ticket.unwrap_or(node), "title").clone());
    item.insert("status", status);
    item.insert("priority", ticket.map_or(Value::Null, ticket_priority));
    item.insert(
        "execution_mode",
        match ticket {
            Some(ticket) => first_present_body(Some(node), ticket, "execution_mode"),
            None => field("execution_mode"),
        },
    );
    item.insert(
        "ticket_created_at",
        ticket.map_or(Value::Null, |ticket| {
            body(ticket, "ticket_created_at").clone()
        }),
    );
    item.insert(
        "depends_on",
        strings(ticket.map(ticket_depends_on).unwrap_or_default()),
    );
    item.insert("run_id", field("run_id"));
    item.insert("attempt", field("attempt"));
    item.insert("run_state", state.as_str());
    item.insert("provider", run_provider(Some(node)));
    item.insert("branch", field("branch"));
    item.insert("activity", field("activity"));
    item.insert(
        "last_error",
        if matches!(state.as_str(), "merged" | "succeeded") {
            Value::Null
        } else {
            field("last_error")
        },
    );
    for name in [
        "worker_model",
        "worker_effort",
        "worker_sizing_rationale",
        "worker_provider_notes",
    ] {
        item.insert(name, field(name));
    }
    item.insert("run_node_id", node_field(node, "id").clone());
    item.insert(
        "ticket_node_id",
        ticket.map_or(Value::Null, |ticket| node_field(ticket, "id").clone()),
    );
    item
}

fn ticket_item(ctx: &ProgramContext, ticket: usize, status: &str) -> Dict {
    let node = &ctx.tickets[ticket];
    let latest = latest_run(ctx, ticket);
    let sizing_error = ticket_worker_sizing_error(node);
    let mut labels: Vec<String> = ctx
        .blockers
        .get(&node_id(node))
        .map(|blockers| {
            blockers
                .iter()
                .map(|&blocker| ticket_id(&ctx.tickets[blocker]))
                .collect()
        })
        .unwrap_or_default();
    labels.extend(unsatisfied_dependencies(ctx, ticket));
    let mut seen = HashSet::new();
    labels.retain(|label| !label.is_empty() && seen.insert(label.clone()));
    let run_field = |name: &str| latest.map_or(Value::Null, |run| body(run, name).clone());
    let project = node
        .get("project_id")
        .and_then(Value::as_str)
        .and_then(|id| ctx.projects_by_id.get(id))
        .map(|&project| &ctx.projects[project]);
    let execution_mode = first_present_body(latest, node, "execution_mode");
    let mut item = Dict::new();
    item.insert("project", project_value(project));
    item.insert("ticket_id", ticket_id(node));
    item.insert("title", node_field(node, "title").clone());
    item.insert("status", status);
    item.insert("priority", ticket_priority(node));
    item.insert(
        "execution_mode",
        if execution_mode.truthy() {
            execution_mode
        } else {
            Value::Str("implementation".to_string())
        },
    );
    item.insert("ticket_modified_at", ticket_modified_at(node));
    item.insert("ticket_created_at", body(node, "ticket_created_at").clone());
    item.insert("ticket_state", ticket_state(node));
    item.insert("run_id", run_field("run_id"));
    item.insert("attempt", run_field("attempt"));
    item.insert(
        "run_state",
        latest.map_or(Value::Null, |run| Value::Str(run_state(Some(run)))),
    );
    item.insert(
        "provider",
        latest.map_or(Value::Null, |run| run_provider(Some(run))),
    );
    item.insert("branch", run_field("branch"));
    item.insert("activity", run_field("activity"));
    item.insert(
        "last_error",
        if project_board_state(ctx, ticket) == "done" {
            Value::Null
        } else {
            let error = run_field("last_error");
            if error.truthy() {
                error
            } else {
                sizing_error.clone()
            }
        },
    );
    for name in [
        "worker_model",
        "worker_effort",
        "worker_sizing_rationale",
        "worker_provider_notes",
    ] {
        item.insert(name, first_present_body(latest, node, name));
    }
    item.insert("worker_sizing_error", sizing_error);
    item.insert("depends_on", strings(ticket_depends_on(node)));
    item.insert("blocked_by", strings(labels));
    item.insert("ticket_node_id", node_field(node, "id").clone());
    item
}

fn awaiting_review_item(ctx: &ProgramContext, ticket: usize) -> Dict {
    let status = match run_state(latest_run(ctx, ticket)).as_str() {
        "merge_conflict" => "merge conflict",
        "integration_blocked" => "integration blocked",
        _ => "awaiting review",
    };
    ticket_item(ctx, ticket, status)
}

fn limit_items(mut items: Vec<Dict>, limit: Option<usize>) -> Vec<Dict> {
    if let Some(limit) = limit {
        items.truncate(limit);
    }
    items
}

fn plural(count: usize, noun: &str) -> String {
    if count == 1 {
        format!("{count} {noun}")
    } else {
        format!("{count} {noun}s")
    }
}

fn items_text(
    title: &str,
    noun: &str,
    items: &[Dict],
    ctx: &ProgramContext,
    limit: Option<usize>,
) -> String {
    let projects = plural(ctx.projects.len(), "indexed project");
    if items.is_empty() {
        let empty = match key_text(title).as_str() {
            QUERY_ACTIVE => "No active program runs".to_string(),
            QUERY_DISCOVERY => "No discovery work".to_string(),
            QUERY_READY => "No queued work".to_string(),
            QUERY_BLOCKED => "No blocked work".to_string(),
            QUERY_AWAITING_MERGE => "No tickets awaiting review".to_string(),
            QUERY_DONE => "No done work".to_string(),
            QUERY_STALE_RUNS => "No stale or stalled runs".to_string(),
            QUERY_NEXT => "No immediate program attention items".to_string(),
            _ => format!("No {}", title.to_lowercase()),
        };
        return format!("{empty} across {projects}.");
    }
    let shown = limit.map_or(items.len(), |limit| limit.min(items.len()));
    let mut lines = vec![format!(
        "{title}: {} across {projects}.",
        plural(items.len(), noun)
    )];
    lines.extend(items[..shown].iter().map(item_line));
    if items.len() > shown {
        lines.push(format!("- ... and {} more.", items.len() - shown));
    }
    lines.join("\n")
}

fn summary_text(items: &[Dict], provider: Option<&str>) -> String {
    let provider_text = provider.map_or(String::new(), |provider| {
        format!(" for {}", provider_label(provider))
    });
    let mut lines = vec![format!(
        "Program summary{provider_text}: {}.",
        plural(items.len(), "indexed project")
    )];
    for item in items {
        let number = |field: &str| item.get(field).and_then(Value::py_int).unwrap_or(0);
        let parts = [
            plural(number("open_tickets") as usize, "open ticket"),
            plural(number("active_runs") as usize, "active run"),
            format!("{} blocked", number("blocked")),
            format!("{} awaiting review", number("awaiting_merge")),
            plural(number("stale_runs") as usize, "stale run"),
        ];
        let list = |field: &str| -> Vec<String> {
            item.get(field)
                .and_then(Value::as_list)
                .unwrap_or_default()
                .iter()
                .map(Value::py_str)
                .collect()
        };
        let providers = list("providers").join(", ");
        let providers = if providers.is_empty() {
            "none recorded".to_string()
        } else {
            providers
        };
        let (name, path) = project_name_path(item);
        let mut line = format!(
            "- {name} ({path}): {}. Providers: {providers}.",
            parts.join(", ")
        );
        let health = list("provider_health");
        if !health.is_empty() {
            line.push_str(&format!(" Provider health: {}.", health.join("; ")));
        }
        lines.push(line);
    }
    lines.join("\n")
}

fn project_name_path(item: &Dict) -> (String, String) {
    let project = item.get("project").and_then(Value::as_dict);
    let field = |name: &str| {
        project
            .and_then(|project| project.get(name))
            .map(Value::py_str)
            .unwrap_or_default()
    };
    (field("name"), field("path"))
}

fn item_line(item: &Dict) -> String {
    let (name, path) = project_name_path(item);
    let get = |field: &str| item.get(field).unwrap_or(&Value::Null);
    let mut subject = if get("ticket_id").truthy() {
        get("ticket_id").py_str()
    } else {
        "no ticket".to_string()
    };
    if get("title").truthy() {
        subject.push_str(&format!(" - {}", get("title").py_str()));
    }
    let mut details = vec![if get("attention").truthy() {
        get("attention").py_str()
    } else {
        get("status").py_str()
    }];
    if !matches!(get("run_id"), Value::Null) {
        details.push(format!("run {}", get("run_id").py_str()));
    }
    if !matches!(get("attempt"), Value::Null) {
        details.push(format!("attempt {}", get("attempt").py_str()));
    }
    if get("provider").truthy() {
        details.push(get("provider").py_str());
    }
    if get("worker_effort").truthy() {
        details.push(format!("effort {}", get("worker_effort").py_str()));
    }
    if get("blocked_by").truthy() {
        let blockers: Vec<String> = get("blocked_by")
            .as_list()
            .unwrap_or_default()
            .iter()
            .map(Value::py_str)
            .collect();
        details.push(format!("waiting on {}", blockers.join(", ")));
    }
    if get("activity").truthy() {
        details.push(get("activity").py_str());
    }
    let status = get("status").as_str().unwrap_or("");
    let run_state = get("run_state").as_str().unwrap_or("");
    if get("last_error").truthy()
        && (matches!(status, "stalled" | "failed")
            || matches!(run_state, "failed" | "integration_blocked")
            || get("worker_sizing_error").truthy())
    {
        details.push(get("last_error").py_str());
    }
    format!("- {name} ({path}): {subject} ({}).", details.join("; "))
}

fn response(
    query: &str,
    provider: Option<&str>,
    message: String,
    items: Vec<Dict>,
    ctx: &ProgramContext,
) -> Dict {
    let mut counts = Dict::new();
    counts.insert("projects", ctx.projects.len() as i64);
    counts.insert("items", items.len() as i64);
    let mut response = Dict::new();
    response.insert("query", query);
    response.insert("provider", provider.map(str::to_string));
    response.insert("message", message);
    response.insert(
        "items",
        Value::List(items.into_iter().map(Value::Dict).collect()),
    );
    response.insert("counts", Value::Dict(counts));
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queries_normalise_like_python() {
        assert_eq!(normalize_program_status_query(None).unwrap(), QUERY_SUMMARY);
        assert_eq!(
            normalize_program_status_query(Some("")).unwrap(),
            QUERY_SUMMARY
        );
        assert_eq!(
            normalize_program_status_query(Some(" Look-At Next ")).unwrap(),
            QUERY_NEXT
        );
        assert_eq!(
            normalize_program_status_query(Some("backlog")).unwrap(),
            QUERY_BACKLOG_LANE
        );
        let error = normalize_program_status_query(Some("bogus")).unwrap_err();
        assert_eq!(error.class, "ProgramStatusError");
        assert_eq!(
            error.message,
            "unknown program status query 'bogus'; expected one of active_work, backlog_lane, \
             ready_lane, in_progress_lane, done_lane, discovery_work, ready_work, blocked_work, \
             awaiting_merge, done_work, stale_runs, summary, next"
        );
    }

    #[test]
    fn labels_follow_str_title() {
        assert_eq!(provider_label("codex"), "Codex");
        assert_eq!(provider_label("open_ai"), "Open Ai");
        assert_eq!(provider_label("gpt4o"), "Gpt4O");
        assert_eq!(plural(1, "run"), "1 run");
        assert_eq!(plural(2, "run"), "2 runs");
        assert_eq!(item_limit(0), None);
        assert_eq!(item_limit(900), Some(500));
    }
}
