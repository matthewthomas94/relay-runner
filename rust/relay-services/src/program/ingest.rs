//! `services/graphify_ingest.py`: the Graphify program graph built from the
//! registered projects, their boards (materialized and archived), their
//! Program events, the runs database and, optionally, a lexical file index.
//!
//! The registry, ticket files, run logs and `runs.db` are read-only inputs;
//! every write goes through one `graphify.db` transaction.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

use relay_artifacts::catalog::{DEFAULT_ACTIVITY_FIELDS, validate_catalog_ticket_metadata};
use relay_intents::json::{self, Dict, Value};
use relay_intents::pattern::{self, Regex};
use relay_store::graphify::{
    EDGE_AWAITS_MERGE, EDGE_BELONGS_TO, EDGE_CONTAINS, EDGE_DEPENDS_ON, EDGE_EXECUTES,
    EDGE_MENTIONS_FILE, EDGE_USES_PROVIDER, FileChunk, FileIndex, Graph, GraphifyStore,
    NODE_AGENT_PROVIDER, NODE_PROJECT, NODE_RUN, NODE_TICKET,
};

use super::artifacts::ingest_project_program_events;
use super::{GitOutput, dict_or_empty, get, git, str_or_empty};
use crate::{Error, Result};

pub const ARTIFACT_REF: &str = "refs/heads/relay/artifacts";

/// The keyword arguments of `ingest_registered_projects`.
#[derive(Clone, Debug, Default)]
pub struct IngestOptions {
    pub registry_path: PathBuf,
    pub runs_db_path: Option<PathBuf>,
    pub index_files: bool,
    /// Projects whose inputs have not moved since this store's previous
    /// ingest ([`unchanged_project_inputs`]); ignored when indexing files.
    pub unchanged_repo_paths: BTreeSet<String>,
    pub runs_unchanged: bool,
}

/// The counts `ingest_registered_projects` returns, in Python's key order.
const COUNT_KEYS: [&str; 12] = [
    "projects",
    "tickets",
    "archived_tickets",
    "tickets_deleted",
    "dependencies",
    "runs",
    "runs_deleted",
    "providers",
    "program_events",
    "files_indexed",
    "files_unchanged",
    "files_deleted",
];

struct Counts(Vec<(&'static str, i64)>);

impl Counts {
    fn new() -> Self {
        Self(COUNT_KEYS.iter().map(|key| (*key, 0)).collect())
    }

    fn add(&mut self, key: &str, value: i64) {
        if let Some(entry) = self.0.iter_mut().find(|(name, _)| *name == key) {
            entry.1 += value;
        }
    }

    fn set(&mut self, key: &str, value: i64) {
        if let Some(entry) = self.0.iter_mut().find(|(name, _)| *name == key) {
            entry.1 = value;
        }
    }

    fn into_dict(self) -> Dict {
        let mut dict = Dict::new();
        for (key, value) in self.0 {
            dict.insert(key, value);
        }
        dict
    }
}

/// `ingest_registered_projects`: build the program graph in one transaction
/// and return the counts.
pub fn ingest_registered_projects(store: &GraphifyStore, options: &IngestOptions) -> Result<Dict> {
    let unchanged = if options.index_files {
        BTreeSet::new()
    } else {
        options.unchanged_repo_paths.clone()
    };
    super::in_transaction(store, |graph| ingest(graph, options, &unchanged))
}

/// A file's `(st_ino, st_size, st_mtime_ns, st_ctime_ns)`, or `None`.
pub type StatKey = Option<(u64, u64, i64, i64)>;

fn stat_key(path: &Path) -> StatKey {
    let metadata = fs::metadata(path).ok()?;
    Some((
        metadata.ino(),
        metadata.size(),
        metadata.mtime() * 1_000_000_000 + metadata.mtime_nsec(),
        metadata.ctime() * 1_000_000_000 + metadata.ctime_nsec(),
    ))
}

/// The Git refs an ingest resolves, as `_git_ref_state` reads them without
/// running Git.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RefState {
    NoGit,
    Refs {
        head: Vec<u8>,
        packed_refs: StatKey,
        refs: Vec<(String, StatKey)>,
    },
}

/// A board directory's entries, as `_orchestrator_entries_state` reads them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EntriesState {
    Unavailable { exists: bool },
    Entries(Vec<(String, StatKey)>),
}

/// One registered project's inputs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectInputState {
    pub repo_path: String,
    pub refs: RefState,
    pub entries: EntriesState,
}

/// `registered_projects_input_state`: a cheap identity for everything a
/// ticket-and-run ingest reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputState {
    pub registry: Option<Vec<u8>>,
    pub projects: Vec<ProjectInputState>,
    /// Empty without a runs database; else `runs.db`, `-wal`, `-journal`.
    pub runs: Vec<StatKey>,
}

/// `graph_file_state`: the graph files' identity, so another writer's
/// change forces an ingest.
pub fn graph_file_state(graphify_path: &Path) -> Vec<StatKey> {
    ["", "-wal"]
        .iter()
        .map(|suffix| stat_key(&suffixed(graphify_path, suffix)))
        .collect()
}

fn suffixed(path: &Path, suffix: &str) -> PathBuf {
    let mut text = path.as_os_str().to_os_string();
    text.push(suffix);
    PathBuf::from(text)
}

/// `unchanged_project_inputs(previous, current)`: the projects whose refs and
/// board entries are identical and whether the runs database is, or `None`
/// when the registry changed and every project must be re-read.
pub fn unchanged_project_inputs(
    previous: Option<&InputState>,
    current: Option<&InputState>,
) -> Option<(BTreeSet<String>, bool)> {
    let (previous, current) = (previous?, current?);
    if previous.registry != current.registry {
        return None;
    }
    let mut before: HashMap<&str, &ProjectInputState> = HashMap::new();
    for project in &previous.projects {
        before.insert(&project.repo_path, project);
    }
    let unchanged = current
        .projects
        .iter()
        .filter(|project| before.get(project.repo_path.as_str()) == Some(project))
        .map(|project| project.repo_path.clone())
        .collect();
    Some((unchanged, previous.runs == current.runs))
}

/// `registered_projects_input_state`; `None` when ref storage cannot be read
/// directly, so the caller ingests.
pub fn registered_projects_input_state(
    registry_path: &Path,
    runs_db_path: Option<&Path>,
) -> Result<Option<InputState>> {
    let registry_bytes = fs::read(registry_path).ok();
    let registry = load_registry(registry_path);
    let mut projects = Vec::new();
    if let Some(records) = registry.get("projects").and_then(Value::as_list) {
        for record in records {
            let Some(record) = record.as_dict() else {
                continue;
            };
            let Some(repo_path) = record_repo_path(record)? else {
                continue;
            };
            let repo = Path::new(&repo_path);
            let mut refs = BTreeSet::new();
            refs.insert(artifact_ref(record));
            refs.insert(ARTIFACT_REF.to_string());
            let Some(ref_state) = git_ref_state(repo, refs) else {
                return Ok(None);
            };
            let entries = orchestrator_entries_state(&repo.join(".orchestrator"));
            projects.push(ProjectInputState {
                repo_path,
                refs: ref_state,
                entries,
            });
        }
    }
    let runs = match runs_db_path {
        Some(path) => ["", "-wal", "-journal"]
            .iter()
            .map(|suffix| stat_key(&suffixed(path, suffix)))
            .collect(),
        None => Vec::new(),
    };
    Ok(Some(InputState {
        registry: registry_bytes,
        projects,
        runs,
    }))
}

fn orchestrator_entries_state(directory: &Path) -> EntriesState {
    let Ok(entries) = fs::read_dir(directory) else {
        return EntriesState::Unavailable {
            exists: directory.exists(),
        };
    };
    let mut names: Vec<String> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    EntriesState::Entries(
        names
            .into_iter()
            .map(|name| {
                let key = stat_key(&directory.join(&name));
                (name, key)
            })
            .collect(),
    )
}

fn git_ref_state(repo: &Path, refs: BTreeSet<String>) -> Option<RefState> {
    let git_dir = repo.join(".git");
    if !git_dir.exists() {
        return Some(RefState::NoGit);
    }
    // A linked worktree or reftable store keeps refs elsewhere; ask Git instead.
    if !git_dir.is_dir() || git_dir.join("reftable").exists() {
        return None;
    }
    let head = fs::read(git_dir.join("HEAD")).ok()?;
    let mut names = refs;
    if let Some(reference) = head.strip_prefix(b"ref: ") {
        let reference = String::from_utf8_lossy(reference.trim_ascii()).into_owned();
        names.insert(reference);
    }
    Some(RefState::Refs {
        head,
        packed_refs: stat_key(&git_dir.join("packed-refs")),
        refs: names
            .into_iter()
            .map(|name| {
                let key = stat_key(&git_dir.join(&name));
                (name, key)
            })
            .collect(),
    })
}

/// One ticket the ingest projects: a materialized board file or a verified
/// archive catalog entry.
#[derive(Clone, Debug)]
struct IngestTicket {
    id: String,
    title: String,
    status: String,
    priority: String,
    execution_mode: String,
    depends_on: Vec<String>,
    run_id: Option<i64>,
    canceled: bool,
    body: String,
    verification_blocker: Option<String>,
    verification_resume: Option<String>,
    source_path: String,
    artifact_id: Option<String>,
    history_state: Option<String>,
    archived: bool,
    raw_fields: Option<relay_artifacts::tickets::Fields>,
}

fn ingest(
    graph: &Graph<'_>,
    options: &IngestOptions,
    unchanged: &BTreeSet<String>,
) -> Result<Dict> {
    let registry = load_registry(&options.registry_path);
    let registry_v2 = json::py_eq(&get(&registry, "schema_version"), &Value::Int(2));
    let active_project_id = if registry_v2 {
        get(&registry, "active_project_id")
    } else {
        get(&registry, "activeProjectID")
    };
    let active_project_path = if registry_v2 {
        None
    } else {
        clean_path(Some(&active_project_id))?
    };
    let active_workspace_root_path = clean_path(registry.get("activeWorkspaceRootID"))?;
    let workspace_roots_to_filter: BTreeSet<String> = workspace_root_paths(&registry)?
        .into_iter()
        .filter(|path| {
            active_project_path.as_ref() != Some(path)
                || active_workspace_root_path.as_ref() == Some(path)
        })
        .collect();
    let records: Vec<Value> = registry
        .get("projects")
        .and_then(Value::as_list)
        .map(<[Value]>::to_vec)
        .unwrap_or_default();

    let mut counts = Counts::new();
    let mut projects_by_repo: Vec<(String, Dict)> = Vec::new();
    let mut tickets_by_repo: HashMap<String, HashMap<String, Dict>> = HashMap::new();
    let mut reused_repo_paths: HashSet<String> = HashSet::new();
    let set_project = |projects: &mut Vec<(String, Dict)>, repo: &str, project: Dict| match projects
        .iter_mut()
        .find(|(path, _)| path == repo)
    {
        Some(entry) => entry.1 = project,
        None => projects.push((repo.to_string(), project)),
    };

    for repo_path in &workspace_roots_to_filter {
        delete_existing_project_graph(graph, repo_path)?;
    }

    for record in &records {
        let Some(record) = record.as_dict() else {
            continue;
        };
        if registry_v2 && !get(record, "availability").is_str("available") {
            continue;
        }
        let Some(repo_path) = record_repo_path(record)? else {
            continue;
        };
        if workspace_roots_to_filter.contains(&repo_path) {
            continue;
        }

        if unchanged.contains(&repo_path)
            && let Some(reused) = graph.find_node(NODE_PROJECT, &project_key(&repo_path))?
        {
            // Same registry record, refs and board files as last time.
            let mut ticket_nodes = HashMap::new();
            for node in graph.nodes(Some(NODE_TICKET), Some(&get(&reused, "id").py_str()))? {
                let ticket_id = dict_or_empty(&node, "body")
                    .get("ticket_id")
                    .cloned()
                    .unwrap_or(Value::Null)
                    .py_str();
                ticket_nodes.insert(ticket_id, node);
            }
            counts.add("projects", 1);
            counts.add("tickets", ticket_nodes.len() as i64);
            set_project(&mut projects_by_repo, &repo_path, reused);
            tickets_by_repo.insert(repo_path.clone(), ticket_nodes);
            reused_repo_paths.insert(repo_path);
            continue;
        }

        let record_project_id = if registry_v2 {
            get(record, "project_id")
        } else {
            get(record, "id")
        };
        let display_name = if registry_v2 {
            get(record, "display_name")
        } else {
            get(record, "displayName")
        };
        let title = [display_name.clone(), get(record, "alias")]
            .into_iter()
            .find(Value::truthy)
            .map(|value| value.py_str())
            .unwrap_or_else(|| {
                Path::new(&repo_path)
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_default()
            });
        let project_identity = if record_project_id.truthy() {
            record_project_id.clone()
        } else {
            Value::Str(repo_path.clone())
        };
        let mut body = Dict::new();
        body.insert("project_id", project_identity.clone());
        body.insert("repo_path", repo_path.as_str());
        body.insert("root_path", repo_path.as_str());
        body.insert("alias", get(record, "alias"));
        body.insert("display_name", display_name);
        body.insert("active", json::py_eq(&project_identity, &active_project_id));
        body.insert(
            "last_seen_at",
            if registry_v2 {
                get(record, "last_resolved_at")
            } else {
                get(record, "lastSeenAt")
            },
        );
        body.insert(
            "last_activation_source",
            get(record, "lastActivationSource"),
        );
        body.insert(
            "availability",
            if registry_v2 {
                get(record, "availability")
            } else {
                Value::Str("available".to_string())
            },
        );
        body.insert(
            "remote",
            if registry_v2 {
                get(record, "remote")
            } else {
                Value::Null
            },
        );
        body.insert("providers", dict_or_empty(record, "providers"));
        let project = graph.upsert_node(
            NODE_PROJECT,
            &project_key(&repo_path),
            None,
            Some(&title),
            Some(&body),
            None,
        )?;
        let project_id = get(&project, "id").py_str();
        counts.add("projects", 1);
        set_project(&mut projects_by_repo, &repo_path, project.clone());

        for provider_key in registry_provider_keys(record) {
            upsert_provider(graph, &provider_key)?;
            counts.add("providers", 1);
        }

        let repo = PathBuf::from(&repo_path);
        let artifact_ref = artifact_ref(record);
        let mut tickets: Vec<IngestTicket> = relay_artifacts::tickets::scan_repo(&repo)?
            .into_iter()
            .map(|(path, ticket)| IngestTicket {
                source_path: path.to_string_lossy().into_owned(),
                id: ticket.id,
                title: ticket.title,
                status: ticket.status,
                priority: ticket.priority,
                execution_mode: ticket.execution_mode,
                depends_on: ticket.depends_on,
                run_id: ticket.run_id,
                canceled: ticket.canceled,
                body: ticket.body,
                verification_blocker: ticket.verification_blocker,
                verification_resume: ticket.verification_resume,
                artifact_id: None,
                history_state: None,
                archived: false,
                raw_fields: Some(ticket.raw_fields),
            })
            .collect();
        let materialized_ids: HashSet<String> =
            tickets.iter().map(|ticket| ticket.id.clone()).collect();
        let archived: Vec<IngestTicket> = archive_catalog_tickets(&repo, &artifact_ref)?
            .into_iter()
            .filter(|ticket| !materialized_ids.contains(&ticket.id))
            .collect();
        counts.add("archived_tickets", archived.len() as i64);
        tickets.extend(archived);
        let creation_dates = ticket_creation_dates(&repo, &artifact_ref);
        let mut repo_ticket_nodes: HashMap<String, Dict> = HashMap::new();
        for ticket in &tickets {
            let mut body = Dict::new();
            body.insert("ticket_id", ticket.id.as_str());
            body.insert("state", ticket_state(ticket));
            body.insert("status", ticket.status.as_str());
            body.insert("priority", ticket.priority.as_str());
            body.insert("execution_mode", ticket.execution_mode.as_str());
            body.insert(
                "depends_on",
                Value::List(ticket.depends_on.iter().cloned().map(Value::Str).collect()),
            );
            body.insert("run_id", ticket.run_id.map_or(Value::Null, Value::Int));
            body.insert("canceled", ticket.canceled);
            for field in [
                "worker_model",
                "worker_effort",
                "worker_sizing_rationale",
                "worker_provider_notes",
            ] {
                body.insert(field, ticket_field(ticket, field));
            }
            body.insert("verification_blocker", ticket.verification_blocker.clone());
            body.insert("verification_resume", ticket.verification_resume.clone());
            body.insert("source_path", ticket.source_path.as_str());
            body.insert(
                "ticket_created_at",
                creation_dates
                    .get(&ticket.id)
                    .map_or(Value::Null, |date| Value::Float(*date)),
            );
            body.insert("markdown", ticket.body.as_str());
            body.insert("materialized", !ticket.archived);
            body.insert("artifact_id", ticket.artifact_id.clone());
            body.insert("history_state", ticket.history_state.clone());
            let ticket_node = graph.upsert_node(
                NODE_TICKET,
                &ticket_key(&repo_path, &ticket.id),
                Some(&project_id),
                Some(&ticket.title),
                Some(&body),
                None,
            )?;
            let ticket_node_id = get(&ticket_node, "id").py_str();
            repo_ticket_nodes.insert(ticket.id.clone(), ticket_node);
            counts.add("tickets", 1);
            graph.upsert_edge(&ticket_node_id, &project_id, EDGE_BELONGS_TO, None)?;
            graph.upsert_edge(&project_id, &ticket_node_id, EDGE_CONTAINS, None)?;
        }

        let seen: BTreeSet<String> = repo_ticket_nodes.keys().cloned().collect();
        counts.add(
            "tickets_deleted",
            delete_missing_ticket_nodes(graph, &project, &seen)?,
        );

        let mut dependency_body = Dict::new();
        dependency_body.insert("source", "ticket_frontmatter");
        for ticket in &tickets {
            let Some(ticket_node) = repo_ticket_nodes.get(&ticket.id) else {
                continue;
            };
            for dependency in &ticket.depends_on {
                let Some(dependency_node) = repo_ticket_nodes.get(dependency) else {
                    continue;
                };
                graph.upsert_edge(
                    &get(ticket_node, "id").py_str(),
                    &get(dependency_node, "id").py_str(),
                    EDGE_DEPENDS_ON,
                    Some(&dependency_body),
                )?;
                counts.add("dependencies", 1);
            }
        }

        if options.index_files {
            let ticket_nodes: Vec<Dict> = repo_ticket_nodes.values().cloned().collect();
            let (indexed, unchanged_files, deleted) =
                index_project_files(graph, &project, &repo, &ticket_nodes)?;
            counts.add("files_indexed", indexed);
            counts.add("files_unchanged", unchanged_files);
            counts.add("files_deleted", deleted);
        }

        tickets_by_repo.insert(repo_path, repo_ticket_nodes);
    }

    let mut seen_run_stable_keys: HashSet<String> = HashSet::new();
    let runs = match &options.runs_db_path {
        Some(path) => read_runs(path),
        None => Vec::new(),
    };
    for run in &runs {
        let Some(repo_path) = clean_path(run.get("repo_path"))? else {
            continue;
        };
        let Some(project) = projects_by_repo
            .iter()
            .find(|(path, _)| *path == repo_path)
            .map(|(_, project)| project.clone())
        else {
            continue;
        };
        let project_id = get(&project, "id").py_str();
        if options.runs_unchanged && reused_repo_paths.contains(&repo_path) {
            // Neither the run nor the tickets its program state reads moved.
            seen_run_stable_keys.insert(run_key(&get(run, "id")));
            counts.add("runs", 1);
            continue;
        }

        let ticket_id = json::py_strip(&str_or_empty(run.get("ticket_id"))).to_string();
        let ticket_node = tickets_by_repo
            .get(&repo_path)
            .and_then(|nodes| nodes.get(&ticket_id))
            .cloned();
        let (provider_key, provider_source) = provider_for_run(run)?;
        let mut provider_node = None;
        if let Some(provider_key) = &provider_key {
            provider_node = Some(upsert_provider(graph, provider_key)?);
            counts.add("providers", 1);
        }

        let state = run_state(run.get("state"));
        let program_state = program_state(&state, ticket_node.as_ref());
        let mut body = Dict::new();
        body.insert("run_id", get(run, "id"));
        body.insert("ticket_id", ticket_id.as_str());
        body.insert("attempt", get(run, "attempt"));
        body.insert("provider_key", provider_key.clone());
        body.insert("model_alias", first_present(run, &["model_alias", "model"]));
        for field in [
            "worker_model",
            "worker_effort",
            "worker_sizing_rationale",
            "worker_provider_notes",
        ] {
            body.insert(field, get(run, field));
        }
        body.insert("state", state.as_str());
        body.insert("raw_state", get(run, "state"));
        body.insert("program_state", program_state.as_str());
        body.insert("branch", get(run, "branch"));
        body.insert(
            "execution_mode",
            match run.get("execution_mode") {
                Some(mode) if mode.truthy() => mode.clone(),
                _ => Value::Str("implementation".to_string()),
            },
        );
        for field in [
            "workspace_path",
            "log_path",
            "started_at",
            "ended_at",
            "exit_code",
            "last_error",
            "activity",
            "activity_at",
        ] {
            body.insert(field, get(run, field));
        }
        body.insert(
            "provider",
            match (&provider_key, &provider_source) {
                (Some(key), Some(source)) => {
                    let mut provider = Dict::new();
                    provider.insert("key", key.as_str());
                    provider.insert("source", source.as_str());
                    Value::Dict(provider)
                }
                _ => Value::Null,
            },
        );
        let title =
            json::py_strip(&format!("{ticket_id} run {}", get(run, "id").py_str())).to_string();
        let run_node = graph.upsert_node(
            NODE_RUN,
            &run_key(&get(run, "id")),
            Some(&project_id),
            Some(&title),
            Some(&body),
            None,
        )?;
        let run_node_id = get(&run_node, "id").py_str();
        seen_run_stable_keys.insert(get(&run_node, "stable_key").py_str());
        counts.add("runs", 1);
        graph.upsert_edge(&run_node_id, &project_id, EDGE_BELONGS_TO, None)?;
        graph.upsert_edge(&project_id, &run_node_id, EDGE_CONTAINS, None)?;
        if let Some(ticket_node) = &ticket_node {
            let ticket_node_id = get(ticket_node, "id").py_str();
            graph.upsert_edge(&run_node_id, &ticket_node_id, EDGE_EXECUTES, None)?;
            if program_state == "awaiting_merge" {
                graph.upsert_edge(&ticket_node_id, &run_node_id, EDGE_AWAITS_MERGE, None)?;
            }
        }
        if let Some(provider_node) = &provider_node {
            graph.upsert_edge(
                &run_node_id,
                &get(provider_node, "id").py_str(),
                EDGE_USES_PROVIDER,
                None,
            )?;
        }
    }

    if options.runs_db_path.is_some() {
        let project_ids: HashSet<String> = projects_by_repo
            .iter()
            .map(|(_, project)| get(project, "id").py_str())
            .collect();
        let mut deleted = 0;
        for node in graph.nodes(Some(NODE_RUN), None)? {
            let belongs =
                matches!(node.get("project_id"), Some(Value::Str(id)) if project_ids.contains(id));
            if !belongs || seen_run_stable_keys.contains(&get(&node, "stable_key").py_str()) {
                continue;
            }
            if graph.delete_node(&get(&node, "id").py_str())? {
                deleted += 1;
            }
        }
        counts.set("runs_deleted", deleted);
    }

    for (repo_path, project) in &projects_by_repo {
        if reused_repo_paths.contains(repo_path) {
            continue;
        }
        counts.add(
            "program_events",
            ingest_project_program_events(graph, project, repo_path)?,
        );
    }

    Ok(counts.into_dict())
}

/// `_load_registry(path)`: the registry object, or `{}`.
fn load_registry(path: &Path) -> Dict {
    fs::read_to_string(path)
        .ok()
        .and_then(|text| json::parse(&text))
        .and_then(|value| match value {
            Value::Dict(dict) => Some(dict),
            _ => None,
        })
        .unwrap_or_default()
}

/// `_workspace_root_paths(registry)`.
fn workspace_root_paths(registry: &Dict) -> Result<BTreeSet<String>> {
    let mut paths = BTreeSet::new();
    let Some(roots) = registry.get("workspaceRoots").and_then(Value::as_list) else {
        return Ok(paths);
    };
    for record in roots {
        let Some(record) = record.as_dict() else {
            continue;
        };
        let value = [record.get("rootPath"), record.get("id")]
            .into_iter()
            .flatten()
            .find(|value| value.truthy())
            .cloned();
        if let Some(path) = clean_path(value.as_ref())? {
            paths.insert(path);
        }
    }
    Ok(paths)
}

const IGNORED_CODE_INDEX_DIRS: [&str; 21] = [
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
];

/// `_LANGUAGE_BY_SUFFIX`; its keys are `_INDEXABLE_SUFFIXES`.
const LANGUAGE_BY_SUFFIX: [(&str, &str); 31] = [
    (".c", "c"),
    (".cc", "cpp"),
    (".cpp", "cpp"),
    (".css", "css"),
    (".go", "go"),
    (".h", "c"),
    (".hpp", "cpp"),
    (".html", "html"),
    (".java", "java"),
    (".js", "javascript"),
    (".json", "json"),
    (".jsx", "javascript"),
    (".kt", "kotlin"),
    (".m", "objective-c"),
    (".md", "markdown"),
    (".mm", "objective-cpp"),
    (".plist", "plist"),
    (".py", "python"),
    (".rb", "ruby"),
    (".rs", "rust"),
    (".scss", "scss"),
    (".sh", "shell"),
    (".sql", "sql"),
    (".swift", "swift"),
    (".toml", "toml"),
    (".ts", "typescript"),
    (".tsx", "typescript"),
    (".txt", "text"),
    (".xml", "xml"),
    (".yaml", "yaml"),
    (".yml", "yaml"),
];

const INDEXABLE_NAMES: [&str; 8] = [
    ".gitignore",
    "AGENTS.md",
    "CLAUDE.md",
    "Dockerfile",
    "Makefile",
    "Package.swift",
    "README",
    "README.md",
];

const MAX_INDEX_BYTES: u64 = 1_000_000;
const CHUNK_LINES: usize = 120;

/// `PurePath.suffix` for a file name.
fn suffix(name: &str) -> &str {
    match name.rfind('.') {
        Some(index) if index > 0 && index < name.len() - 1 => &name[index..],
        _ => "",
    }
}

fn language_for_suffix(suffix: &str) -> Option<&'static str> {
    let lower = suffix.to_lowercase();
    LANGUAGE_BY_SUFFIX
        .iter()
        .find(|(known, _)| *known == lower)
        .map(|(_, language)| *language)
}

/// `_index_project_files`: index the project's text files, returning
/// `(files_indexed, files_unchanged, files_deleted)`.
fn index_project_files(
    graph: &Graph<'_>,
    project: &Dict,
    repo: &Path,
    ticket_nodes: &[Dict],
) -> Result<(i64, i64, i64)> {
    let (mut indexed, mut unchanged) = (0, 0);
    if !repo.is_dir() {
        return Ok((0, 0, 0));
    }
    let project_id = get(project, "id").py_str();
    let mut seen = BTreeSet::new();
    let mut files = Vec::new();
    walk_indexable_files(repo, &mut files);
    for path in files {
        let Ok(metadata) = fs::metadata(&path) else {
            continue;
        };
        if metadata.size() > MAX_INDEX_BYTES {
            continue;
        }
        let Some(rel_path) = path
            .strip_prefix(repo)
            .ok()
            .and_then(Path::to_str)
            .map(str::to_string)
        else {
            continue;
        };
        seen.insert(rel_path.clone());
        let mtime_ns = metadata.mtime() * 1_000_000_000 + metadata.mtime_nsec();
        let size = metadata.size() as i64;
        if let Some(manifest) = graph.get_file_manifest(&project_id, &rel_path)?
            && matches!(manifest.get("deleted_at"), None | Some(Value::Null))
            && json::py_eq(&get(&manifest, "size_bytes"), &Value::Int(size))
            && json::py_eq(&get(&manifest, "mtime_ns"), &Value::Int(mtime_ns))
        {
            unchanged += 1;
            if let Some(file_node) = graph.get_node(&get(&manifest, "id").py_str())? {
                link_ticket_file_mentions(graph, ticket_nodes, &file_node, &rel_path)?;
            }
            continue;
        }
        let Some(text) = read_text_file(&path) else {
            seen.remove(&rel_path);
            continue;
        };
        let name = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let manifest = graph.upsert_file_index(&FileIndex {
            project_id: project_id.clone(),
            rel_path: rel_path.clone(),
            language: Some(language_for_name(&name)),
            size_bytes: size,
            mtime_ns: Some(mtime_ns),
            content_hash: None,
            chunks: chunk_text(&text),
        })?;
        indexed += 1;
        if let Some(file_node) = graph.get_node(&get(&manifest, "id").py_str())? {
            link_ticket_file_mentions(graph, ticket_nodes, &file_node, &rel_path)?;
        }
    }
    let deleted = graph.mark_missing_files_deleted(&project_id, &seen)? as i64;
    Ok((indexed, unchanged, deleted))
}

/// `os.walk` top-down over sorted names, pruning ignored directories and
/// never following a symbolic link, collecting the indexable files.
fn walk_indexable_files(directory: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    let mut names: Vec<(String, PathBuf, bool, bool)> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| {
            let path = entry.path();
            let link = entry.file_type().is_ok_and(|kind| kind.is_symlink());
            // `scandir`'s `is_dir()` follows links: a linked directory is
            // listed with the directories and never descended into.
            let is_dir = path.is_dir();
            (
                entry.file_name().to_string_lossy().into_owned(),
                path,
                is_dir,
                link,
            )
        })
        .collect();
    names.sort_by(|left, right| left.0.cmp(&right.0));
    let mut directories = Vec::new();
    for (name, path, is_dir, link) in names {
        if is_dir {
            if !link && !IGNORED_CODE_INDEX_DIRS.contains(&name.as_str()) && !name.ends_with(".app")
            {
                directories.push(path);
            }
            continue;
        }
        if link {
            continue;
        }
        if is_indexable_name(&name) {
            files.push(path);
        }
    }
    for directory in directories {
        walk_indexable_files(&directory, files);
    }
}

/// `_is_indexable_path(path)`.
fn is_indexable_name(name: &str) -> bool {
    if INDEXABLE_NAMES.contains(&name) {
        return true;
    }
    if name.starts_with('.') {
        return false;
    }
    language_for_suffix(suffix(name)).is_some()
}

/// `_read_text_file(path)`: UTF-8 text without NUL bytes, or `None`.
fn read_text_file(path: &Path) -> Option<String> {
    let data = fs::read(path).ok()?;
    if data.contains(&0) {
        return None;
    }
    String::from_utf8(data).ok()
}

/// `_chunk_text(text)`: runs of 120 lines.
fn chunk_text(text: &str) -> Vec<FileChunk> {
    let lines = relay_artifacts::pystr::splitlines(text);
    let mut chunks = Vec::new();
    for start in (0..lines.len()).step_by(CHUNK_LINES) {
        let chunk_lines = &lines[start..(start + CHUNK_LINES).min(lines.len())];
        chunks.push(FileChunk {
            chunk_ordinal: Some(chunks.len() as i64),
            start_line: Some(start as i64 + 1),
            end_line: Some((start + chunk_lines.len()) as i64),
            text: chunk_lines.join("\n"),
        });
    }
    if chunks.is_empty() && !text.is_empty() {
        chunks.push(FileChunk {
            chunk_ordinal: Some(0),
            start_line: Some(1),
            end_line: Some(1),
            text: text.to_string(),
        });
    }
    chunks
}

/// `_language_for_path(path)`.
fn language_for_name(name: &str) -> String {
    match name {
        "Dockerfile" | "Makefile" => name.to_lowercase(),
        "Package.swift" => "swift".to_string(),
        _ => language_for_suffix(suffix(name))
            .unwrap_or("text")
            .to_string(),
    }
}

/// `_link_ticket_file_mentions`: a ticket that names the file mentions it.
fn link_ticket_file_mentions(
    graph: &Graph<'_>,
    ticket_nodes: &[Dict],
    file_node: &Dict,
    rel_path: &str,
) -> Result<()> {
    for ticket_node in ticket_nodes {
        let body = dict_or_empty(ticket_node, "body");
        let haystack = format!(
            "{}\n{}",
            str_or_empty(ticket_node.get("title")),
            str_or_empty(body.get("markdown"))
        );
        if haystack.contains(rel_path) {
            let mut edge_body = Dict::new();
            edge_body.insert("source", "ticket_markdown");
            edge_body.insert("rel_path", rel_path);
            graph.upsert_edge(
                &get(ticket_node, "id").py_str(),
                &get(file_node, "id").py_str(),
                EDGE_MENTIONS_FILE,
                Some(&edge_body),
            )?;
        }
    }
    Ok(())
}

/// `_repo_path(record)`.
fn record_repo_path(record: &Dict) -> Result<Option<String>> {
    let value = ["last_resolved_path", "selected_path", "repoPath", "id"]
        .iter()
        .filter_map(|key| record.get(key))
        .find(|value| value.truthy())
        .cloned();
    clean_path(value.as_ref())
}

/// `_clean_path(value)`: the resolved path, or `None` for blank text.
fn clean_path(value: Option<&Value>) -> Result<Option<String>> {
    let text = str_or_empty(value);
    let text = json::py_strip(&text);
    if text.is_empty() {
        return Ok(None);
    }
    super::resolve_path(text).map(Some)
}

fn project_key(repo_path: &str) -> String {
    format!("repo:{repo_path}")
}

fn ticket_key(repo_path: &str, ticket_id: &str) -> String {
    format!("{}:{ticket_id}", project_key(repo_path))
}

fn run_key(run_id: &Value) -> String {
    format!("run:{}", run_id.py_str())
}

/// `_delete_existing_project_graph(store, repo_path)`.
fn delete_existing_project_graph(graph: &Graph<'_>, repo_path: &str) -> Result<()> {
    let Some(project) = graph.find_node(NODE_PROJECT, &project_key(repo_path))? else {
        return Ok(());
    };
    let project_id = get(&project, "id").py_str();
    for node in graph.nodes(None, Some(&project_id))? {
        graph.delete_node(&get(&node, "id").py_str())?;
    }
    graph.delete_node(&project_id)?;
    Ok(())
}

/// `_delete_missing_ticket_nodes`.
fn delete_missing_ticket_nodes(
    graph: &Graph<'_>,
    project: &Dict,
    seen_ticket_ids: &BTreeSet<String>,
) -> Result<i64> {
    let prefix = get(project, "stable_key").py_str();
    let seen: HashSet<String> = seen_ticket_ids
        .iter()
        .map(|ticket_id| format!("{prefix}:{ticket_id}"))
        .collect();
    let mut deleted = 0;
    for node in graph.nodes(Some(NODE_TICKET), Some(&get(project, "id").py_str()))? {
        if seen.contains(&get(&node, "stable_key").py_str()) {
            continue;
        }
        if graph.delete_node(&get(&node, "id").py_str())? {
            deleted += 1;
        }
    }
    Ok(deleted)
}

/// `_artifact_ref(record)`.
fn artifact_ref(record: &Dict) -> String {
    if let Some(remote) = record.get("remote").and_then(Value::as_dict) {
        let configured = [remote.get("artifactRef"), remote.get("artifact_ref")]
            .into_iter()
            .flatten()
            .find(|value| value.truthy())
            .map(|value| json::py_strip(&value.py_str()).to_string())
            .unwrap_or_default();
        if !configured.is_empty() {
            return configured;
        }
    }
    ARTIFACT_REF.to_string()
}

// -- the archive catalog ------------------------------------------------------

/// Verified archive tickets by `(repo, confirmed head, catalog exists)`, as
/// the `lru_cache` of `_archive_catalog_tickets_at_head` keeps them.
type ArchiveKey = (String, String, bool);
type ArchiveCache = Vec<(ArchiveKey, Vec<IngestTicket>)>;
static ARCHIVE_CACHE: LazyLock<Mutex<ArchiveCache>> = LazyLock::new(|| Mutex::new(Vec::new()));
const ARCHIVE_CACHE_SIZE: usize = 64;

/// `_ARCHIVE_PROVEN_LINES`: per repository, the head and the catalog lines
/// whose identity and historical metadata were proven at it.
type ProvenLines = HashMap<String, (String, HashSet<String>)>;
static ARCHIVE_PROVEN_LINES: LazyLock<Mutex<ProvenLines>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

static ARCHIVE_OID: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile_full(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", false));
static ARCHIVE_PLAIN_TICKET_ID: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile_full(r"[A-Za-z0-9][A-Za-z0-9._-]*", false));
static ACTIVITY_AT: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile_full(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z", false)
});

fn fullmatch(regex: &Regex, text: &str) -> bool {
    pattern::search(regex, text)
}

/// `_archive_catalog_tickets`: the metadata-only terminal cards of the
/// confirmed ref, verified.
fn archive_catalog_tickets(repo: &Path, artifact_ref: &str) -> Result<Vec<IngestTicket>> {
    let catalog_path = repo.join(".orchestrator/archive-index.jsonl");
    let unavailable = || Error::value("archive catalog confirmed ref is unavailable");
    if !repo.join(".git").exists() {
        if catalog_path.exists() {
            return Err(unavailable());
        }
        return Ok(Vec::new());
    }
    let confirmed = git(
        repo,
        &[
            "rev-parse",
            "--verify",
            &format!("{artifact_ref}^{{commit}}"),
        ],
        None,
    );
    if !confirmed.ok() {
        if catalog_path.exists() {
            return Err(unavailable());
        }
        return Ok(Vec::new());
    }
    let head = json::py_strip(&confirmed.text()).to_string();
    let key = (
        relay_artifacts::paths::resolve(&repo.to_string_lossy()),
        head,
        catalog_path.exists(),
    );
    {
        let cache = ARCHIVE_CACHE
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if let Some((_, tickets)) = cache.iter().find(|(cached, _)| *cached == key) {
            return Ok(tickets.clone());
        }
    }
    let tickets = archive_catalog_tickets_at_head(&key.0, &key.1, key.2)?;
    let mut cache = ARCHIVE_CACHE
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    cache.retain(|(cached, _)| *cached != key);
    if cache.len() >= ARCHIVE_CACHE_SIZE {
        cache.remove(0);
    }
    cache.push((key, tickets.clone()));
    Ok(tickets)
}

/// `_archive_catalog_tickets_at_head`: verify one immutable archive commit.
fn archive_catalog_tickets_at_head(
    repo_text: &str,
    head: &str,
    materialized_catalog_exists: bool,
) -> Result<Vec<IngestTicket>> {
    let repo = Path::new(repo_text);
    let catalog = git(
        repo,
        &["show", &format!("{head}:.orchestrator/archive-index.jsonl")],
        None,
    );
    if !catalog.ok() {
        if materialized_catalog_exists {
            return Err(Error::value(
                "confirmed artifact ref has no archive catalog",
            ));
        }
        return Ok(Vec::new());
    }
    let normalized = normalize_newlines(&catalog.stdout);
    let text = relay_artifacts::pystr::decode_utf8(&normalized).map_err(|error| {
        Error::value(format!("archive catalog is unavailable: {}", error.message))
    })?;
    let lines = relay_artifacts::pystr::splitlines(text);
    // Structural checks first, in catalog order. A structural failure is
    // raised only after every earlier line passed its identity checks, so
    // the first failing line is still the one reported.
    let mut entries: Vec<(usize, &str, Dict)> = Vec::new();
    let mut structural_error = None;
    for (index, line) in lines.iter().enumerate() {
        match archive_catalog_entry(line, index + 1) {
            Ok(Some(entry)) => entries.push((index + 1, line, entry)),
            Ok(None) => {}
            Err(error) => {
                structural_error = Some(error);
                break;
            }
        }
    }
    let proven = archive_lines_proven_before(repo, repo_text, head);
    let unproven: Vec<&Dict> = entries
        .iter()
        .filter(|(_, line, _)| !proven.contains(*line))
        .map(|(_, _, entry)| entry)
        .collect();
    let mut identities = ArchiveIdentities::new(repo, head, &unproven);
    let mut tickets = Vec::new();
    let mut seen_ids = HashSet::new();
    let mut proven_now = HashSet::new();
    for (line_number, line, entry) in &entries {
        let ticket_id = entry.string("ticket_id");
        if !proven.contains(*line) {
            let (failure, historical) = identities.ticket_bytes(entry);
            if let Some(failure) = failure {
                return Err(Error::value(format!(
                    "archive catalog line {line_number} has {failure} historical identity"
                )));
            }
            if let Err(error) =
                validate_catalog_ticket_metadata(entry, &historical, &DEFAULT_ACTIVITY_FIELDS)
            {
                if error.kind == relay_artifacts::ErrorKind::CatalogSemantic {
                    return Err(Error::value(format!(
                        "archive catalog line {line_number} has mismatched historical metadata: {}",
                        error.message
                    )));
                }
                return Err(error.into());
            }
        }
        proven_now.insert(line.to_string());
        let status = get(entry, "status").py_str();
        let lowered = status.to_lowercase();
        if !matches!(lowered.as_str(), "done" | "canceled" | "cancelled") {
            if get(entry, "state").is_str("deleted_tombstone") {
                // Delete accepts unfinished work. Its verified tombstone is
                // recovery metadata, not terminal history, so keep it off
                // the board rather than resurfacing deleted backlog cards.
                continue;
            }
            return Err(Error::value(format!(
                "archive catalog line {line_number} has nonterminal history"
            )));
        }
        if seen_ids.contains(&ticket_id) {
            return Err(Error::value(format!(
                "archive catalog repeats ticket ID {ticket_id}"
            )));
        }
        let dependencies = match entry.get("dependencies") {
            None => Some(Vec::new()),
            Some(Value::List(items)) => items
                .iter()
                .map(|item| match item {
                    Value::Str(text) if !json::py_strip(text).is_empty() => Some(text.clone()),
                    _ => None,
                })
                .collect(),
            Some(_) => None,
        };
        let Some(dependencies) = dependencies else {
            return Err(Error::value(format!(
                "archive catalog line {line_number} has invalid dependencies"
            )));
        };
        seen_ids.insert(ticket_id.clone());
        tickets.push(IngestTicket {
            id: ticket_id,
            title: get(entry, "title").py_str(),
            canceled: matches!(lowered.as_str(), "canceled" | "cancelled"),
            status,
            priority: "unknown".to_string(),
            execution_mode: "implementation".to_string(),
            depends_on: dependencies,
            run_id: None,
            body: String::new(),
            verification_blocker: None,
            verification_resume: None,
            source_path: String::new(),
            artifact_id: Some(get(entry, "artifact_id").py_str()),
            history_state: Some(get(entry, "state").py_str()),
            archived: true,
            raw_fields: None,
        });
    }
    if let Some(error) = structural_error {
        return Err(error);
    }
    ARCHIVE_PROVEN_LINES
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .insert(repo_text.to_string(), (head.to_string(), proven_now));
    Ok(tickets)
}

/// `_archive_lines_proven_before`: lines proven at an ancestor head stay
/// proven.
fn archive_lines_proven_before(repo: &Path, repo_text: &str, head: &str) -> HashSet<String> {
    let previous = ARCHIVE_PROVEN_LINES
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .get(repo_text)
        .cloned();
    let Some((previous_head, lines)) = previous else {
        return HashSet::new();
    };
    if previous_head == head {
        return lines;
    }
    let ancestor = git(
        repo,
        &["merge-base", "--is-ancestor", &previous_head, head],
        None,
    );
    if ancestor.ok() { lines } else { HashSet::new() }
}

/// `_archive_catalog_entry`: a structurally valid entry, `None` for a
/// skipped line.
fn archive_catalog_entry(line: &str, line_number: usize) -> Result<Option<Dict>> {
    if json::py_strip(line).is_empty() {
        return Ok(None);
    }
    let Some(value) = json::parse(line) else {
        return Err(Error::value(format!(
            "archive catalog line {line_number} is invalid JSON"
        )));
    };
    let Value::Dict(entry) = value else {
        return Err(Error::value(format!(
            "archive catalog line {line_number} is not an object"
        )));
    };
    let missing: Vec<&str> = [
        "artifact_id",
        "ticket_id",
        "title",
        "status",
        "activity_at",
        "state",
    ]
    .into_iter()
    .filter(|key| entry.text(key).is_empty())
    .collect();
    if !missing.is_empty() {
        return Err(Error::value(format!(
            "archive catalog line {line_number} is missing: {}",
            missing.join(", ")
        )));
    }
    let state = get(&entry, "state");
    if !(state.is_str("archived") || state.is_str("deleted_tombstone")) {
        return Ok(None);
    }
    let ticket_id = get(&entry, "ticket_id").py_str();
    let activity_at = get(&entry, "activity_at").py_str();
    let invalid_activity = || {
        Error::value(format!(
            "archive catalog line {line_number} has invalid activity_at"
        ))
    };
    if !fullmatch(&ACTIVITY_AT, &activity_at) {
        return Err(invalid_activity());
    }
    let without_z = &activity_at[..activity_at.len() - 1];
    if relay_artifacts::isotime::fromisoformat(&format!("{without_z}+00:00")).is_err() {
        return Err(invalid_activity());
    }
    if !get(&entry, "ticket_path").is_str(&format!(".orchestrator/{ticket_id}.md"))
        || !fullmatch(&ARCHIVE_OID, &str_or_empty(entry.get("ticket_blob")))
        || !fullmatch(&ARCHIVE_OID, &str_or_empty(entry.get("source_commit")))
    {
        return Err(Error::value(format!(
            "archive catalog line {line_number} has invalid historical identity"
        )));
    }
    Ok(Some(entry))
}

/// The universal-newline translation of `text=True` output, on bytes.
fn normalize_newlines(content: &[u8]) -> Vec<u8> {
    let mut result = Vec::with_capacity(content.len());
    let mut index = 0;
    while index < content.len() {
        match content[index] {
            b'\r' => {
                result.push(b'\n');
                if content.get(index + 1) == Some(&b'\n') {
                    index += 1;
                }
            }
            byte => result.push(byte),
        }
        index += 1;
    }
    result
}

/// A source commit's `.orchestrator` tree: `(type, object id)` by path.
type SourceTree = HashMap<String, (String, String)>;

/// `_ArchiveIdentities`: catalog identities resolved against one confirmed
/// head in a few batches, falling back to the per-commit checks for
/// anything the batches cannot prove.
struct ArchiveIdentities<'r> {
    repo: &'r Path,
    head: String,
    source_trees: HashMap<String, Option<SourceTree>>,
    paths: HashMap<(String, String), (String, String)>,
    blobs: HashMap<String, Vec<u8>>,
}

impl<'r> ArchiveIdentities<'r> {
    fn new(repo: &'r Path, head: &str, entries: &[&Dict]) -> Self {
        let mut identities = Self {
            repo,
            head: head.to_string(),
            source_trees: HashMap::new(),
            paths: HashMap::new(),
            blobs: HashMap::new(),
        };
        if entries.is_empty() {
            return identities;
        }
        let rev_list = git(repo, &["rev-list", head], None);
        let ancestors: HashSet<String> = if rev_list.ok() {
            rev_list
                .text()
                .split_whitespace()
                .map(str::to_string)
                .collect()
        } else {
            HashSet::new()
        };
        let lookups: BTreeSet<(String, String)> = entries
            .iter()
            .filter(|entry| {
                ancestors.contains(&get(entry, "source_commit").py_str())
                    && fullmatch(&ARCHIVE_PLAIN_TICKET_ID, &get(entry, "ticket_id").py_str())
            })
            .map(|entry| {
                (
                    get(entry, "source_commit").py_str(),
                    get(entry, "ticket_path").py_str(),
                )
            })
            .collect();
        let lookups: Vec<(String, String)> = lookups.into_iter().collect();
        let requests: Vec<String> = lookups
            .iter()
            .map(|(commit, path)| format!("{commit}:{path}"))
            .collect();
        if let Some(resolved) = git_batch_check(repo, &requests) {
            for (lookup, (object_id, object_type)) in lookups.into_iter().zip(resolved) {
                // A reachable commit whose tree lacks the path is a mismatch,
                // exactly as when `ls-tree` does not list it.
                identities.paths.insert(
                    lookup,
                    (
                        object_type.unwrap_or_else(|| "missing".to_string()),
                        object_id,
                    ),
                );
            }
        }
        let blob_ids: BTreeSet<String> = entries
            .iter()
            .filter(|entry| {
                let key = (
                    get(entry, "source_commit").py_str(),
                    get(entry, "ticket_path").py_str(),
                );
                identities.paths.get(&key)
                    == Some(&("blob".to_string(), get(entry, "ticket_blob").py_str()))
            })
            .map(|entry| get(entry, "ticket_blob").py_str())
            .collect();
        identities.blobs = git_batch_blobs(repo, &blob_ids.into_iter().collect::<Vec<_>>());
        identities
    }

    /// `(failure, historical ticket bytes)`; the failure names the error.
    fn ticket_bytes(&mut self, entry: &Dict) -> (Option<&'static str>, Vec<u8>) {
        let source_commit = get(entry, "source_commit").py_str();
        let ticket_path = get(entry, "ticket_path").py_str();
        let ticket_blob = get(entry, "ticket_blob").py_str();
        let tree_entry = match self
            .paths
            .get(&(source_commit.clone(), ticket_path.clone()))
        {
            Some(found) => Some(found.clone()),
            None => {
                if !self.source_trees.contains_key(&source_commit) {
                    let tree = self.source_tree(&source_commit);
                    self.source_trees.insert(source_commit.clone(), tree);
                }
                match &self.source_trees[&source_commit] {
                    None => return (Some("unreachable"), Vec::new()),
                    Some(tree) => tree.get(&ticket_path).cloned(),
                }
            }
        };
        if tree_entry != Some(("blob".to_string(), ticket_blob.clone())) {
            return (Some("mismatched"), Vec::new());
        }
        if let Some(historical) = self.blobs.get(&ticket_blob) {
            return (None, historical.clone());
        }
        let result = git(self.repo, &["cat-file", "blob", &ticket_blob], None);
        if !result.ok() {
            return (Some("unreachable"), Vec::new());
        }
        let historical = normalize_newlines(&result.stdout);
        self.blobs.insert(ticket_blob, historical.clone());
        (None, historical)
    }

    fn source_tree(&self, source_commit: &str) -> Option<SourceTree> {
        let exists = git(
            self.repo,
            &["cat-file", "-e", &format!("{source_commit}^{{commit}}")],
            None,
        );
        if !exists.ok()
            || !git(
                self.repo,
                &["merge-base", "--is-ancestor", source_commit, &self.head],
                None,
            )
            .ok()
        {
            return None;
        }
        let tree = git(
            self.repo,
            &["ls-tree", "-r", source_commit, "--", ".orchestrator"],
            None,
        );
        if !tree.ok() {
            return None;
        }
        let mut source_tree = HashMap::new();
        for tree_line in relay_artifacts::pystr::splitlines(&tree.text()) {
            let (metadata, found, tree_path) = relay_artifacts::pystr::partition(tree_line, "\t");
            let parts: Vec<&str> = metadata.split_whitespace().collect();
            if !found || parts.len() != 3 {
                continue;
            }
            source_tree.insert(
                tree_path.to_string(),
                (parts[1].to_string(), parts[2].to_string()),
            );
        }
        Some(source_tree)
    }
}

/// `_git_batch`: one Git process answering every request line.
fn git_batch(repo: &Path, arguments: &[&str], requests: &[String]) -> Option<Vec<u8>> {
    if requests.is_empty() {
        return Some(Vec::new());
    }
    let input: String = requests
        .iter()
        .map(|request| format!("{request}\n"))
        .collect();
    let output: GitOutput = git(repo, arguments, Some(input.as_bytes()));
    if output.status == -1 && output.stdout.is_empty() {
        return None;
    }
    output.ok().then_some(output.stdout)
}

/// `_git_batch_check`: `(object id, type)` per request, with no type when
/// missing.
fn git_batch_check(repo: &Path, requests: &[String]) -> Option<Vec<(String, Option<String>)>> {
    let output = git_batch(
        repo,
        &["cat-file", "--batch-check=%(objectname) %(objecttype)"],
        requests,
    )?;
    let text = String::from_utf8_lossy(&output);
    let mut lines: Vec<&str> = text.split('\n').collect();
    if lines.last() == Some(&"") {
        lines.pop();
    }
    if lines.len() != requests.len() {
        return None;
    }
    Some(
        lines
            .into_iter()
            .map(|line| {
                let (object_id, _, object_type) = relay_artifacts::pystr::partition(line, " ");
                if fullmatch(&ARCHIVE_OID, object_id)
                    && !object_type.is_empty()
                    && !object_type.contains(' ')
                {
                    (object_id.to_string(), Some(object_type.to_string()))
                } else {
                    (String::new(), None)
                }
            })
            .collect(),
    )
}

/// `_git_batch_blobs`: blobs read in one process; absent ones left out.
fn git_batch_blobs(repo: &Path, object_ids: &[String]) -> HashMap<String, Vec<u8>> {
    let mut blobs = HashMap::new();
    let Some(output) = git_batch(repo, &["cat-file", "--batch"], object_ids) else {
        return blobs;
    };
    let mut offset = 0;
    for object_id in object_ids {
        let Some(header_end) = output[offset.min(output.len())..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|position| position + offset)
        else {
            break;
        };
        let header = String::from_utf8_lossy(&output[offset..header_end]).into_owned();
        let header: Vec<&str> = header.split(' ').collect();
        offset = header_end + 1;
        if header.len() != 3
            || header[2].is_empty()
            || !header[2].chars().all(|c| c.is_ascii_digit())
        {
            continue;
        }
        let Ok(size) = header[2].parse::<usize>() else {
            continue;
        };
        let end = (offset + size).min(output.len());
        let content = &output[offset.min(output.len())..end];
        offset += size + 1;
        if header[0] == object_id && header[1] == "blob" && content.len() == size {
            // The per-blob read decoded text and normalized line endings;
            // validate exactly the same bytes.
            blobs.insert(object_id.clone(), normalize_newlines(content));
        }
    }
    blobs
}

// -- ticket creation dates ----------------------------------------------------

type CreationDates = HashMap<String, f64>;
type CreationDatesCache = Vec<((String, String), CreationDates)>;
static CREATION_DATES_CACHE: LazyLock<Mutex<CreationDatesCache>> =
    LazyLock::new(|| Mutex::new(Vec::new()));
const CREATION_DATES_CACHE_SIZE: usize = 32;

/// `_ticket_creation_dates`: the first recorded addition of each ticket file
/// across source and artifact history.
fn ticket_creation_dates(repo: &Path, artifact_ref: &str) -> CreationDates {
    let mut heads: Vec<String> = Vec::new();
    for reference in ["HEAD", artifact_ref] {
        let result = git(repo, &["rev-parse", "--verify", reference], None);
        if result.ok() {
            let head = json::py_strip(&result.text()).to_string();
            if !heads.contains(&head) {
                heads.push(head);
            }
        }
    }
    let repo_text = repo.to_string_lossy().into_owned();
    let mut dates = CreationDates::new();
    for head in heads {
        for (ticket_id, timestamp) in creation_dates_at_head(&repo_text, &head) {
            let entry = dates.entry(ticket_id).or_insert(timestamp);
            *entry = entry.min(timestamp);
        }
    }
    dates
}

static TICKET_FILE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile_full(r"\.orchestrator/[^/]+\.md", false));

fn creation_dates_at_head(repo_text: &str, head: &str) -> CreationDates {
    let key = (repo_text.to_string(), head.to_string());
    {
        let cache = CREATION_DATES_CACHE
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if let Some((_, dates)) = cache.iter().find(|(cached, _)| *cached == key) {
            return dates.clone();
        }
    }
    let result = git(
        Path::new(repo_text),
        &[
            "log",
            "--format=created:%ct",
            "--name-only",
            "--diff-filter=A",
            head,
            "--",
            ".orchestrator/*.md",
        ],
        None,
    );
    let mut dates = CreationDates::new();
    let mut timestamp: Option<f64> = None;
    if result.ok() {
        for line in relay_artifacts::pystr::splitlines(&result.text()) {
            if let Some(seconds) = line.strip_prefix("created:") {
                timestamp = json::py_strip(seconds).parse().ok();
            } else if let Some(timestamp) = timestamp
                && fullmatch(&TICKET_FILE, line)
            {
                let name = &line[".orchestrator/".len()..];
                let ticket_id = name.strip_suffix(".md").unwrap_or(name).to_string();
                let entry = dates.entry(ticket_id).or_insert(timestamp);
                *entry = entry.min(timestamp);
            }
        }
    }
    let mut cache = CREATION_DATES_CACHE
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    if cache.len() >= CREATION_DATES_CACHE_SIZE {
        cache.remove(0);
    }
    cache.push((key, dates.clone()));
    dates
}

// -- runs and providers -------------------------------------------------------

/// `_ticket_state(ticket)`.
fn ticket_state(ticket: &IngestTicket) -> String {
    if ticket.canceled {
        return "canceled".to_string();
    }
    if ticket.status.is_empty() {
        "unknown".to_string()
    } else {
        ticket.status.clone()
    }
}

/// `_ticket_field(ticket, field)`.
fn ticket_field(ticket: &IngestTicket, field: &str) -> Value {
    let Some(raw) = &ticket.raw_fields else {
        return Value::Null;
    };
    let value = json::py_strip(raw.get(field).unwrap_or_default());
    if value.is_empty() {
        Value::Null
    } else {
        Value::Str(value.to_string())
    }
}

/// `_registry_provider_keys(record)`.
fn registry_provider_keys(record: &Dict) -> Vec<String> {
    let Some(providers) = record.get("providers").and_then(Value::as_dict) else {
        return Vec::new();
    };
    providers
        .iter()
        .map(|(key, _)| normalize_provider(Some(&Value::Str(key.to_string()))))
        .filter(|key| !key.is_empty())
        .collect()
}

/// `_upsert_provider(store, provider_key)`.
fn upsert_provider(graph: &Graph<'_>, provider_key: &str) -> Result<Dict> {
    let provider_key = normalize_provider(Some(&Value::Str(provider_key.to_string())));
    let title = match provider_key.as_str() {
        "codex" => "Codex".to_string(),
        "claude" => "Claude".to_string(),
        other => super::title_case(&other.replace('_', " ")),
    };
    let mut body = Dict::new();
    body.insert("provider_key", provider_key.as_str());
    Ok(graph.upsert_node(
        NODE_AGENT_PROVIDER,
        &provider_key,
        None,
        Some(&title),
        Some(&body),
        None,
    )?)
}

/// `_read_runs(path)`: every run row, by id; `[]` when unreadable.
fn read_runs(path: &Path) -> Vec<Dict> {
    if !path.is_file() {
        return Vec::new();
    }
    let read = || -> rusqlite::Result<Vec<Dict>> {
        let connection = rusqlite::Connection::open_with_flags(
            path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        let mut statement = connection.prepare("SELECT * FROM runs ORDER BY id")?;
        let columns: Vec<String> = statement.column_names().map(str::to_string).collect();
        let rows = statement.query_map([], |row| {
            let mut record = Dict::new();
            for (index, column) in columns.iter().enumerate() {
                record.insert(column, relay_store::sql::sql_to_json(row.get(index)?));
            }
            Ok(record)
        })?;
        rows.collect()
    };
    read().unwrap_or_default()
}

/// `_provider_for_run(run)`: the provider and where it was read.
fn provider_for_run(run: &Dict) -> Result<(Option<String>, Option<String>)> {
    for key in [
        "provider_key",
        "provider",
        "agent_kind",
        "agent_provider",
        "agent",
    ] {
        let provider = normalize_provider(run.get(key));
        if !provider.is_empty() {
            return Ok((Some(provider), Some(format!("run.{key}"))));
        }
    }
    if let Some(provider) = infer_provider_from_log(run.get("log_path"))? {
        return Ok((Some(provider), Some("run.log".to_string())));
    }
    Ok((None, None))
}

/// `_normalize_provider(value)`: `codex`, `claude`, any other name
/// normalised, or empty.
fn normalize_provider(value: Option<&Value>) -> String {
    let text = json::py_strip(&str_or_empty(value)).to_lowercase();
    if text.is_empty() {
        return text;
    }
    if text.contains("codex") {
        return "codex".to_string();
    }
    if text.contains("claude") {
        return "claude".to_string();
    }
    text.replace([' ', '-'], "_")
}

/// `_infer_provider_from_log(path)`: the provider a run log's first 50 lines
/// name.
fn infer_provider_from_log(path_value: Option<&Value>) -> Result<Option<String>> {
    let Some(path) = clean_path(path_value)? else {
        return Ok(None);
    };
    let Ok(file) = fs::File::open(&path) else {
        return Ok(None);
    };
    let mut reader = BufReader::new(file);
    for _ in 0..50 {
        let mut line = Vec::new();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let line = String::from_utf8_lossy(&line).into_owned();
        if let Some(provider) = provider_from_log_line(&line)? {
            return Ok(Some(provider));
        }
    }
    Ok(None)
}

/// `_provider_from_log_line(line)`.
fn provider_from_log_line(line: &str) -> Result<Option<String>> {
    let stripped = json::py_strip(line);
    if stripped.is_empty() {
        return Ok(None);
    }
    let Some(payload) = json::parse(stripped) else {
        let lower = stripped.to_lowercase();
        if lower.contains("codex") {
            return Ok(Some("codex".to_string()));
        }
        if lower.contains("claude") {
            return Ok(Some("claude".to_string()));
        }
        return Ok(None);
    };
    let Value::Dict(payload) = payload else {
        return Err(Error::new(
            "AttributeError",
            format!(
                "'{}' object has no attribute 'get'",
                relay_artifacts::pystr::type_name(&payload)
            ),
        ));
    };
    let event_type = str_or_empty(payload.get("type"));
    if ["thread.", "item.", "turn."]
        .iter()
        .any(|prefix| event_type.starts_with(prefix))
    {
        return Ok(Some("codex".to_string()));
    }
    if matches!(
        event_type.as_str(),
        "assistant" | "user" | "result" | "system"
    ) {
        return Ok(Some("claude".to_string()));
    }
    let provider = normalize_provider(payload.get("provider"));
    Ok((!provider.is_empty()).then_some(provider))
}

/// `_run_state(raw_state)`.
fn run_state(raw_state: Option<&Value>) -> String {
    let state = json::py_strip(&str_or_empty(raw_state))
        .to_lowercase()
        .replace(['-', ' '], "_");
    let mapped = match state.as_str() {
        "claimed" | "running" => "active",
        "reviewing" => "reviewing",
        "awaiting_review" | "awaitingreview" => "awaiting_review",
        "merge_conflict" | "mergeconflict" => "merge_conflict",
        "integration_blocked" | "integrationblocked" => "integration_blocked",
        "merged" => "merged",
        "succeeded" | "success" | "done" | "spikecompleted" | "spike_completed" => "succeeded",
        "verification_blocked" | "verificationblocked" => "verification_blocked",
        "failed" | "failure" | "timed_out" | "timeout" => "failed",
        "stalled" => "stalled",
        "canceled" | "cancelled" => "canceled",
        "" => "unknown",
        other => return other.to_string(),
    };
    mapped.to_string()
}

/// `_program_state(state, ticket_node)`.
fn program_state(state: &str, ticket_node: Option<&Dict>) -> String {
    if matches!(
        state,
        "awaiting_review" | "merge_conflict" | "integration_blocked"
    ) {
        return state.to_string();
    }
    let Some(ticket_node) = ticket_node.filter(|_| state == "succeeded") else {
        return state.to_string();
    };
    let ticket_state = str_or_empty(dict_or_empty(ticket_node, "body").get("state"));
    if ticket_state != "done" {
        "awaiting_merge".to_string()
    } else {
        "succeeded".to_string()
    }
}

/// `_first_present(values, *keys)`.
fn first_present(values: &Dict, keys: &[&str]) -> Value {
    keys.iter()
        .filter_map(|key| values.get(key))
        .find(|value| !matches!(value, Value::Null))
        .cloned()
        .unwrap_or(Value::Null)
}
