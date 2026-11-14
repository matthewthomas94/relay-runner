//! `services/session_capture.py`: structured session review entries written
//! to the selected Program authority. An artifact-enabled project commits a
//! durable event before Graphify is refreshed; a legacy project keeps the
//! projection-only path. Codex and Claude share both schemas.

use std::path::{Path, PathBuf};

use relay_artifacts::store::ArtifactStore;
use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256::hex_digest;
use relay_store::graphify::{
    EDGE_BELONGS_TO, EDGE_BLOCKS, EDGE_CONTAINS, EDGE_RELATED_TO, Graph, NODE_DECISION, NODE_IDEA,
    NODE_PROGRAM_EVENT, NODE_PROJECT, NODE_RISK, NODE_RUN, NODE_STATUS, NODE_TICKET,
};

use super::artifacts::{
    DurableEvent, durable_program_event, ingest_project_program_events, write_program_events,
};
use super::{dict_or_empty, get, optional_text, str_or_empty};
use crate::{Error, Result};

/// `CAPTURE_NODE_KINDS`.
pub const CAPTURE_NODE_KINDS: [&str; 5] = [
    NODE_PROGRAM_EVENT,
    NODE_DECISION,
    NODE_RISK,
    NODE_IDEA,
    NODE_STATUS,
];

/// `_KIND_ALIASES`, sorted by alias as the error message lists them.
const KIND_ALIASES: [(&str, &str); 15] = [
    ("blocked", NODE_RISK),
    ("blocker", NODE_RISK),
    ("decision", NODE_DECISION),
    ("event", NODE_PROGRAM_EVENT),
    ("idea", NODE_IDEA),
    ("note", NODE_PROGRAM_EVENT),
    ("notes", NODE_PROGRAM_EVENT),
    ("program-event", NODE_PROGRAM_EVENT),
    ("program_event", NODE_PROGRAM_EVENT),
    ("risk", NODE_RISK),
    ("shipped", NODE_PROGRAM_EVENT),
    ("shipped_work", NODE_PROGRAM_EVENT),
    ("started", NODE_PROGRAM_EVENT),
    ("started_work", NODE_PROGRAM_EVENT),
    ("status", NODE_STATUS),
];

/// `_EVENT_TYPES`.
fn event_type_for(kind: &str) -> Option<&'static str> {
    match kind {
        "event" | "program_event" | "program-event" | "note" | "notes" => Some("note"),
        "shipped" | "shipped_work" => Some("shipped_work"),
        "started" | "started_work" => Some("started_work"),
        _ => None,
    }
}

const SESSION_CAPTURE_ERROR: &str = "SessionCaptureError";

fn capture_error(message: impl Into<String>) -> Error {
    Error::new(SESSION_CAPTURE_ERROR, message)
}

/// The keyword arguments of `capture_session_review`. Values arrive as the
/// HTTP body carries them.
#[derive(Clone, Debug)]
pub struct CaptureRequest {
    pub repo_path: Option<Value>,
    pub entries: Option<Value>,
    pub ticket_id: Option<Value>,
    pub run_id: Option<Value>,
    pub provider: Option<Value>,
    pub context: Option<Value>,
    pub capture_id: Option<Value>,
    pub source: String,
    /// Seconds since the epoch; `None` is now.
    pub occurred_at: Option<f64>,
}

impl Default for CaptureRequest {
    fn default() -> Self {
        Self {
            repo_path: None,
            entries: None,
            ticket_id: None,
            run_id: None,
            provider: None,
            context: None,
            capture_id: None,
            source: "session_capture".to_string(),
            occurred_at: None,
        }
    }
}

/// The artifact authority of an artifact-enabled project.
pub struct ArtifactAuthority<'a> {
    pub store: &'a ArtifactStore,
    /// The daemon's writer device id; empty is refused.
    pub device_id: Option<&'a str>,
}

struct Entry {
    node_kind: &'static str,
    entry_kind: String,
    title: String,
    body: String,
    event_type: String,
    risk_type: String,
    status: String,
    ticket_id: Option<String>,
    run_id: Value,
    raw: Value,
}

/// `capture_session_review`: the response the capture route returns, keys in
/// Python's order.
pub fn capture_session_review(
    graph: &Graph<'_>,
    request: &CaptureRequest,
    artifact: Option<&ArtifactAuthority<'_>>,
) -> Result<Dict> {
    let entries = normalize_entries(request.entries.as_ref())?;
    let repo = resolve_repo_path(request.repo_path.as_ref())?;
    let project = resolve_or_create_project(graph, repo.as_deref())?;
    let default_ticket = resolve_ticket(
        graph,
        repo.as_deref(),
        project.as_ref(),
        request.ticket_id.as_ref(),
    )?;
    let default_run = resolve_run(graph, request.run_id.as_ref())?;
    let occurred_at = request.occurred_at.unwrap_or_else(now);
    let capture_id = capture_id(
        request.capture_id.as_ref(),
        repo.as_deref(),
        &entries,
        request.ticket_id.as_ref(),
        request.run_id.as_ref(),
        occurred_at,
    );
    let provider_key = normalize_provider(request.provider.as_ref());

    let mut counts: Vec<(&str, i64)> = CAPTURE_NODE_KINDS.iter().map(|kind| (*kind, 0)).collect();
    let mut count = |kind: &str| {
        if let Some(entry) = counts.iter_mut().find(|(name, _)| *name == kind) {
            entry.1 += 1;
        }
    };
    let mut links = 0i64;
    let mut created: Vec<Value> = Vec::new();
    let mut resolved = Vec::new();
    let mut durable_documents = Vec::new();

    for (index, entry) in entries.iter().enumerate() {
        let entry_ticket_id = match entry.ticket_id.as_deref() {
            Some(ticket_id) => Some(Value::Str(ticket_id.to_string())),
            None => request.ticket_id.clone(),
        };
        let entry_ticket = resolve_ticket(
            graph,
            repo.as_deref(),
            project.as_ref(),
            entry_ticket_id.as_ref(),
        )?
        .or_else(|| default_ticket.clone());
        let entry_run_id = if entry.run_id.truthy() {
            Some(entry.run_id.clone())
        } else {
            request.run_id.clone()
        };
        let entry_run = resolve_run(graph, entry_run_id.as_ref())?.or_else(|| default_run.clone());
        let entry_project = match &project {
            Some(project) => Some(project.clone()),
            None => project_from_evidence(graph, entry_ticket.as_ref(), entry_run.as_ref())?,
        };
        if let Some(authority) = artifact {
            if repo.is_none() || entry_project.is_none() {
                return Err(capture_error(
                    "artifact-backed capture requires confirmed project scope",
                ));
            }
            let stable_key = format!("capture:{capture_id}:{index}");
            let ticket_id = ticket_id_of(entry_ticket.as_ref());
            durable_documents.push(Value::Dict(durable_program_event(&DurableEvent {
                project_id: &authority.store.project_id,
                stable_key: &stable_key,
                node_kind: entry.node_kind,
                capture_id: &capture_id,
                entry_index: index as i64,
                summary: &entry.title,
                details: Some(&entry.body),
                occurred_at,
                source: &request.source,
                provider: provider_key.as_deref(),
                ticket_id: ticket_id.as_deref(),
                run_id: run_id_of(entry_run.as_ref()),
                event_type: Some(&entry.event_type),
                risk_type: Some(&entry.risk_type),
                status: Some(&entry.status),
            })?));
        }
        resolved.push((index, entry, entry_ticket, entry_run, entry_project));
    }

    let mut artifact_result = None;
    if let Some(authority) = artifact {
        let device_id = authority.device_id.filter(|device| !device.is_empty());
        let Some(device_id) = device_id else {
            return Err(capture_error(
                "artifact-backed capture requires a writer device ID",
            ));
        };
        let documents = Value::List(durable_documents.clone());
        let writer_digest = hex_digest(json::dumps_compact_sorted(&documents).as_bytes());
        let documents: Vec<Dict> = durable_documents
            .into_iter()
            .filter_map(|document| match document {
                Value::Dict(dict) => Some(dict),
                _ => None,
            })
            .collect();
        let result = write_program_events(
            authority.store,
            &documents,
            &format!("program-capture:{}", &writer_digest[..40]),
            device_id,
            "pm",
            provider_key.as_deref(),
        )?;
        let (Some(project), Some(repo)) = (&project, &repo) else {
            unreachable!("artifact capture has confirmed scope");
        };
        ingest_project_program_events(graph, project, repo)?;
        for (index, entry, ..) in &resolved {
            let node = graph
                .find_node(entry.node_kind, &format!("capture:{capture_id}:{index}"))?
                .ok_or_else(|| {
                    capture_error(format!(
                        "durable capture projection is missing entry {index}"
                    ))
                })?;
            let node_id = get(&node, "id").py_str();
            count(&get(&node, "kind").py_str());
            let node_links = (graph.edges(None, Some(&node_id), None)?.len()
                + graph.edges(None, None, Some(&node_id))?.len())
                as i64;
            links += node_links;
            created.push(created_entry(&node, node_links));
        }
        artifact_result = Some(result);
    } else {
        for (index, entry, entry_ticket, entry_run, entry_project) in &resolved {
            let project_id = entry_project
                .as_ref()
                .map(|project| get(project, "id").py_str());
            let body = node_body(
                &capture_id,
                *index,
                entry,
                repo.as_deref(),
                entry_ticket.as_ref(),
                entry_run.as_ref(),
                provider_key.as_deref(),
                request.context.as_ref(),
                &request.source,
                occurred_at,
            );
            let node = graph.upsert_node(
                entry.node_kind,
                &format!("capture:{capture_id}:{index}"),
                project_id.as_deref(),
                Some(&entry.title),
                Some(&body),
                None,
            )?;
            count(&get(&node, "kind").py_str());
            let linked = link_capture_node(
                graph,
                &node,
                entry_project.as_ref(),
                entry_ticket.as_ref(),
                entry_run.as_ref(),
                &capture_id,
                entry,
            )?;
            links += linked;
            created.push(created_entry(&node, linked));
        }
    }

    let mut result = Dict::new();
    result.insert("capture_id", capture_id.as_str());
    result.insert(
        "message",
        message(
            created.len(),
            repo.as_deref(),
            provider_key.as_deref(),
            artifact_result.is_some(),
        ),
    );
    result.insert("nodes", Value::List(created));
    let mut nonzero = Dict::new();
    for (kind, value) in counts {
        if value != 0 {
            nonzero.insert(kind, value);
        }
    }
    result.insert("counts", nonzero);
    result.insert("links", links);
    result.insert("provider", provider_key.map_or(Value::Null, Value::Str));
    result.insert("repo_path", repo.map_or(Value::Null, Value::Str));
    if let Some(write) = artifact_result {
        result.insert("artifact_commit", write.commit_id);
        result.insert(
            "artifact_event_ids",
            Value::List(write.event_ids.into_iter().map(Value::Str).collect()),
        );
        result.insert("artifact_idempotent", write.idempotent);
        result.insert("durable_authority", "relay/artifacts");
    }
    Ok(result)
}

fn created_entry(node: &Dict, links: i64) -> Value {
    let mut entry = Dict::new();
    entry.insert("id", get(node, "id"));
    entry.insert("kind", get(node, "kind"));
    entry.insert("title", get(node, "title"));
    entry.insert("links", links);
    Value::Dict(entry)
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

/// The items `enumerate(entries)` walks for a truthy value.
fn iterate(entries: &Value) -> Result<Vec<Value>> {
    match entries {
        Value::List(items) => Ok(items.clone()),
        Value::Dict(dict) => Ok(dict
            .iter()
            .map(|(key, _)| Value::Str(key.to_string()))
            .collect()),
        Value::Str(text) => Ok(text.chars().map(|c| Value::Str(c.to_string())).collect()),
        other => Err(Error::new(
            "TypeError",
            format!(
                "'{}' object is not iterable",
                relay_artifacts::pystr::type_name(other)
            ),
        )),
    }
}

/// `_normalize_entries(entries)`.
fn normalize_entries(entries: Option<&Value>) -> Result<Vec<Entry>> {
    let Some(entries) = entries.filter(|entries| entries.truthy()) else {
        return Err(capture_error("entries is required"));
    };
    let mut normalized = Vec::new();
    for (index, raw_value) in iterate(entries)?.into_iter().enumerate() {
        let Value::Dict(raw) = &raw_value else {
            return Err(capture_error(format!("entry {index} must be an object")));
        };
        let kind_value = [raw.get("kind"), raw.get("type")]
            .into_iter()
            .flatten()
            .find(|value| value.truthy())
            .cloned()
            .unwrap_or_else(|| Value::Str("note".to_string()));
        let raw_kind = key(Some(&kind_value));
        let Some(node_kind) = KIND_ALIASES
            .iter()
            .find(|(alias, _)| *alias == raw_kind)
            .map(|(_, kind)| *kind)
        else {
            let expected: Vec<&str> = KIND_ALIASES.iter().map(|(alias, _)| *alias).collect();
            return Err(capture_error(format!(
                "entry {index} has unsupported kind {}; expected one of {}",
                json::str_repr(&raw_kind),
                expected.join(", ")
            )));
        };
        let mut title = first_text(
            raw,
            &[
                "title", "summary", "decision", "idea", "risk", "status", "note",
            ],
        );
        if title.is_empty() {
            title = default_title(node_kind, &raw_kind);
        }
        normalized.push(Entry {
            node_kind,
            body: first_text(raw, &["body", "details", "description", "note"]),
            event_type: event_type(raw, &raw_kind),
            risk_type: risk_type(raw, &raw_kind),
            status: first_text(raw, &["status", "state"]),
            ticket_id: optional_text(raw.get("ticket_id")),
            run_id: get(raw, "run_id"),
            entry_kind: raw_kind,
            title,
            raw: raw_value.clone(),
        });
    }
    Ok(normalized)
}

/// `_node_body`, for the projection-only path.
#[allow(clippy::too_many_arguments)]
fn node_body(
    capture_id: &str,
    index: usize,
    entry: &Entry,
    repo: Option<&str>,
    ticket: Option<&Dict>,
    run: Option<&Dict>,
    provider_key: Option<&str>,
    context: Option<&Value>,
    source: &str,
    occurred_at: f64,
) -> Dict {
    let mut body = Dict::new();
    body.insert("capture_id", capture_id);
    body.insert("capture_source", source);
    body.insert("entry_index", index as i64);
    body.insert("entry_kind", entry.entry_kind.as_str());
    body.insert("summary", entry.title.as_str());
    body.insert("details", entry.body.as_str());
    body.insert("provider_key", provider_key.map(str::to_string));
    body.insert("context", optional_text(context));
    body.insert("occurred_at", Value::Float(occurred_at));
    let mut evidence = Dict::new();
    evidence.insert("repo_path", repo.map(str::to_string));
    evidence.insert("ticket_id", ticket_id_of(ticket));
    evidence.insert("run_id", run_id_of(run).map_or(Value::Null, Value::Int));
    body.insert("evidence", evidence);
    body.insert("raw_entry", entry.raw.clone());
    if entry.node_kind == NODE_PROGRAM_EVENT {
        body.insert("event_type", entry.event_type.as_str());
    }
    if entry.node_kind == NODE_RISK {
        body.insert("risk_type", entry.risk_type.as_str());
    }
    if entry.node_kind == NODE_STATUS {
        let status = if entry.status.is_empty() {
            &entry.title
        } else {
            &entry.status
        };
        body.insert("status", status.as_str());
    }
    body
}

/// `_link_capture_node`: the edges of a projection-only capture node.
fn link_capture_node(
    graph: &Graph<'_>,
    node: &Dict,
    project: Option<&Dict>,
    ticket: Option<&Dict>,
    run: Option<&Dict>,
    capture_id: &str,
    entry: &Entry,
) -> Result<i64> {
    let mut links = 0;
    let mut body = Dict::new();
    body.insert("source", "session_capture");
    body.insert("capture_id", capture_id);
    let node_id = get(node, "id").py_str();
    if let Some(project) = project {
        let project_id = get(project, "id").py_str();
        graph.upsert_edge(&node_id, &project_id, EDGE_BELONGS_TO, Some(&body))?;
        graph.upsert_edge(&project_id, &node_id, EDGE_CONTAINS, Some(&body))?;
        links += 2;
    }
    if let Some(ticket) = ticket {
        let ticket_id = get(ticket, "id").py_str();
        graph.upsert_edge(&node_id, &ticket_id, EDGE_RELATED_TO, Some(&body))?;
        links += 1;
        if get(node, "kind").is_str(NODE_RISK) && entry.risk_type == "blocker" {
            graph.upsert_edge(&node_id, &ticket_id, EDGE_BLOCKS, Some(&body))?;
            links += 1;
        }
    }
    if let Some(run) = run {
        graph.upsert_edge(
            &node_id,
            &get(run, "id").py_str(),
            EDGE_RELATED_TO,
            Some(&body),
        )?;
        links += 1;
    }
    Ok(links)
}

/// `_resolve_or_create_project(store, repo)`.
fn resolve_or_create_project(graph: &Graph<'_>, repo: Option<&str>) -> Result<Option<Dict>> {
    let Some(repo) = repo else {
        return Ok(None);
    };
    let stable_key = format!("repo:{repo}");
    if let Some(existing) = graph.find_node(NODE_PROJECT, &stable_key)? {
        return Ok(Some(existing));
    }
    let name = Path::new(repo)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| repo.to_string());
    let mut body = Dict::new();
    body.insert("repo_path", repo);
    body.insert("root_path", repo);
    body.insert("source", "session_capture");
    Ok(Some(graph.upsert_node(
        NODE_PROJECT,
        &stable_key,
        None,
        Some(&name),
        Some(&body),
        None,
    )?))
}

/// `_resolve_ticket`: the ticket node, scanned from the board when Graphify
/// does not have it yet.
fn resolve_ticket(
    graph: &Graph<'_>,
    repo: Option<&str>,
    project: Option<&Dict>,
    ticket_id: Option<&Value>,
) -> Result<Option<Dict>> {
    let Some(ticket_id) = optional_text(ticket_id) else {
        return Ok(None);
    };
    if let Some(project) = project {
        let stable_key = format!("{}:{ticket_id}", get(project, "stable_key").py_str());
        if let Some(existing) = graph.find_node(NODE_TICKET, &stable_key)? {
            return Ok(Some(existing));
        }
        if let Some(repo) = repo
            && let Some((path, ticket)) = scan_ticket(Path::new(repo), &ticket_id)?
        {
            let project_id = get(project, "id").py_str();
            let mut body = Dict::new();
            body.insert("ticket_id", ticket.id.as_str());
            body.insert("state", ticket.status.as_str());
            body.insert("status", ticket.status.as_str());
            body.insert("priority", ticket.priority.as_str());
            body.insert(
                "depends_on",
                Value::List(ticket.depends_on.iter().cloned().map(Value::Str).collect()),
            );
            body.insert("run_id", ticket.run_id.map_or(Value::Null, Value::Int));
            body.insert("canceled", ticket.canceled);
            body.insert("source_path", path.to_string_lossy().into_owned());
            body.insert("markdown", ticket.body.as_str());
            body.insert("source", "session_capture");
            let node = graph.upsert_node(
                NODE_TICKET,
                &stable_key,
                Some(&project_id),
                Some(&ticket.title),
                Some(&body),
                None,
            )?;
            let node_id = get(&node, "id").py_str();
            graph.upsert_edge(&node_id, &project_id, EDGE_BELONGS_TO, None)?;
            graph.upsert_edge(&project_id, &node_id, EDGE_CONTAINS, None)?;
            return Ok(Some(node));
        }
    }
    let mut matches: Vec<Dict> = graph
        .nodes(Some(NODE_TICKET), None)?
        .into_iter()
        .filter(|node| ticket_id_of(Some(node)).as_deref() == Some(ticket_id.as_str()))
        .collect();
    Ok(if matches.len() == 1 {
        matches.pop()
    } else {
        None
    })
}

/// `_resolve_run(store, run_id)`.
fn resolve_run(graph: &Graph<'_>, run_id: Option<&Value>) -> Result<Option<Dict>> {
    let Some(run_id) = normalize_run_id(run_id) else {
        return Ok(None);
    };
    Ok(graph.find_node(NODE_RUN, &format!("run:{run_id}"))?)
}

/// `_project_from_evidence(store, ticket, run)`.
fn project_from_evidence(
    graph: &Graph<'_>,
    ticket: Option<&Dict>,
    run: Option<&Dict>,
) -> Result<Option<Dict>> {
    let project_id = [ticket, run]
        .into_iter()
        .flatten()
        .map(|node| get(node, "project_id"))
        .find(Value::truthy);
    let Some(project_id) = project_id else {
        return Ok(None);
    };
    let project = graph.get_node(&project_id.py_str())?;
    Ok(project.filter(|project| get(project, "kind").is_str(NODE_PROJECT)))
}

/// `_scan_ticket(repo, ticket_id)`.
fn scan_ticket(
    repo: &Path,
    ticket_id: &str,
) -> Result<Option<(PathBuf, relay_artifacts::tickets::Ticket)>> {
    Ok(relay_artifacts::tickets::scan_repo(repo)?
        .into_iter()
        .find(|(_, ticket)| ticket.id == ticket_id))
}

/// `_resolve_repo_path(repo_path)`.
fn resolve_repo_path(repo_path: Option<&Value>) -> Result<Option<String>> {
    optional_text(repo_path)
        .map(|text| super::resolve_path(&text))
        .transpose()
}

/// `_capture_id`: the explicit id, or one derived from the capture.
fn capture_id(
    explicit: Option<&Value>,
    repo: Option<&str>,
    entries: &[Entry],
    ticket_id: Option<&Value>,
    run_id: Option<&Value>,
    occurred_at: f64,
) -> String {
    if let Some(explicit) = optional_text(explicit) {
        return explicit;
    }
    let mut payload = Dict::new();
    payload.insert("repo", repo.map(str::to_string));
    payload.insert(
        "entries",
        Value::List(entries.iter().map(|entry| entry.raw.clone()).collect()),
    );
    payload.insert("ticket_id", ticket_id.cloned().unwrap_or(Value::Null));
    payload.insert("run_id", run_id.cloned().unwrap_or(Value::Null));
    payload.insert("occurred_at", Value::Float(occurred_at));
    let encoded = json::dumps_sorted(&Value::Dict(payload));
    let digest = relay_store::sha1::hex_digest(encoded.as_bytes());
    format!("{}-{}", (occurred_at * 1000.0) as i64, &digest[..10])
}

/// `_message(nodes, repo, provider, durable=…)`.
fn message(count: usize, repo: Option<&str>, provider: Option<&str>, durable: bool) -> String {
    let repo_text = repo.map(|repo| format!(" for {repo}")).unwrap_or_default();
    let provider_text = provider
        .map(|provider| format!(" ({provider})"))
        .unwrap_or_default();
    let destination = if durable {
        "into Relay artifacts and refreshed Graphify Core"
    } else {
        "into Graphify Core"
    };
    let noun = if count == 1 { "entry" } else { "entries" };
    format!("Captured {count} session review {noun}{repo_text}{provider_text} {destination}.")
}

/// `_event_type(raw, raw_kind)`.
fn event_type(raw: &Dict, raw_kind: &str) -> String {
    let text = first_text(raw, &["event_type", "event_kind"]);
    if !text.is_empty() {
        return text;
    }
    event_type_for(raw_kind).unwrap_or("note").to_string()
}

/// `_risk_type(raw, raw_kind)`.
fn risk_type(raw: &Dict, raw_kind: &str) -> String {
    if raw_kind == "blocker" || raw_kind == "blocked" {
        return "blocker".to_string();
    }
    let text = first_text(raw, &["risk_type", "risk_kind"]);
    if text.is_empty() {
        "risk".to_string()
    } else {
        text
    }
}

/// `_default_title(node_kind, raw_kind)`.
fn default_title(node_kind: &str, raw_kind: &str) -> String {
    if node_kind == NODE_PROGRAM_EVENT {
        return super::title_case(&event_type_for(raw_kind).unwrap_or("note").replace('_', " "));
    }
    node_kind.replace('_', " ")
}

/// `_first_text(raw, *keys)`.
fn first_text(raw: &Dict, keys: &[&str]) -> String {
    keys.iter()
        .find_map(|key| optional_text(raw.get(key)))
        .unwrap_or_default()
}

/// `_normalize_provider(value)`: unlike the artifact schema, any provider
/// name is kept here, normalised.
fn normalize_provider(value: Option<&Value>) -> Option<String> {
    let text = key(value);
    if text.is_empty() {
        return None;
    }
    if text.contains("codex") {
        return Some("codex".to_string());
    }
    if text.contains("claude") {
        return Some("claude".to_string());
    }
    Some(text.replace(['-', ' '], "_"))
}

/// `_normalize_run_id(value)`: an integer, or `None` for anything else.
fn normalize_run_id(value: Option<&Value>) -> Option<i64> {
    match value {
        None | Some(Value::Null) => None,
        Some(Value::Str(text)) if text.is_empty() => None,
        Some(value) => super::py_int(value).ok(),
    }
}

/// `_ticket_id(ticket)`.
fn ticket_id_of(ticket: Option<&Dict>) -> Option<String> {
    ticket.and_then(|ticket| optional_text(dict_or_empty(ticket, "body").get("ticket_id")))
}

/// `_run_id(run)`.
fn run_id_of(run: Option<&Dict>) -> Option<i64> {
    run.and_then(|run| normalize_run_id(dict_or_empty(run, "body").get("run_id")))
}

/// `_key(value)`: `str(value or "").strip().lower()` with spaces as `_`.
fn key(value: Option<&Value>) -> String {
    json::py_strip(&str_or_empty(value))
        .to_lowercase()
        .replace(' ', "_")
}
