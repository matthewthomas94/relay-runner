//! `services/program_artifacts.py`: the provider-neutral Program event
//! schema, its immutable writes to `refs/heads/relay/artifacts`, the
//! projection of those events into Graphify, and the reviewed export of
//! legacy capture-only Graphify nodes.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use relay_artifacts::ErrorKind as ArtifactErrorKind;
use relay_artifacts::store::{ArtifactStore, Mutation, Operation};
use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256::hex_digest;
use relay_store::graphify::{
    EDGE_BELONGS_TO, EDGE_BLOCKS, EDGE_CONTAINS, EDGE_RELATED_TO, Graph, GraphifyStore,
    NODE_DECISION, NODE_IDEA, NODE_PROGRAM_EVENT, NODE_PROJECT, NODE_RISK, NODE_RUN, NODE_STATUS,
    NODE_TICKET,
};

use super::{dict_or_empty, git, optional_text, random_hex, repr, sorted_keys};
use crate::{Error, Result};

pub const PROGRAM_EVENT_SCHEMA_VERSION: i64 = 1;
pub const PROGRAM_EXPORT_SCHEMA_VERSION: i64 = 1;
/// `PROJECT_CAPTURE_KINDS`, sorted as `sorted()` iterates the frozenset.
pub const PROJECT_CAPTURE_KINDS: [&str; 5] = [
    NODE_DECISION,
    NODE_IDEA,
    NODE_PROGRAM_EVENT,
    NODE_RISK,
    NODE_STATUS,
];
const MAX_REPORT_ISSUES: usize = 500;
const EVENTS_PREFIX: &str = ".orchestrator/program/events/";
const ARTIFACT_REF: &str = "refs/heads/relay/artifacts";

pub(crate) const PROGRAM_ARTIFACT_ERROR: &str = "ProgramArtifactError";
pub(crate) const MIGRATION_ERROR: &str = "ProgramArtifactMigrationError";

fn artifact_error(message: impl Into<String>) -> Error {
    Error::new(PROGRAM_ARTIFACT_ERROR, message)
}

/// `_RECORD_KIND_BY_NODE`.
fn record_kind_for_node(kind: &str) -> Option<&'static str> {
    match kind {
        NODE_PROGRAM_EVENT => Some("program_event"),
        NODE_DECISION => Some("decision"),
        NODE_RISK => Some("risk"),
        NODE_IDEA => Some("idea"),
        NODE_STATUS => Some("status"),
        _ => None,
    }
}

/// `_NODE_KIND_BY_RECORD`.
fn node_kind_for_record(record: &str) -> Option<&'static str> {
    match record {
        "program_event" => Some(NODE_PROGRAM_EVENT),
        "decision" => Some(NODE_DECISION),
        "risk" => Some(NODE_RISK),
        "idea" => Some(NODE_IDEA),
        "status" => Some(NODE_STATUS),
        _ => None,
    }
}

/// The export's test hook, called after each named stage; an error stops
/// the export there.
pub type FailureInjector = dyn Fn(&str) -> Result<()>;

/// `ProgramWriteResult`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProgramWriteResult {
    pub event_ids: Vec<String>,
    pub commit_id: String,
    pub writer_event_id: String,
    pub idempotent: bool,
}

/// A failed export or rebuild: the error, and for a
/// `ProgramArtifactMigrationError` the report it carries.
#[derive(Clone, Debug)]
pub struct MigrationFailure {
    pub error: Error,
    pub report: Option<Dict>,
}

impl From<Error> for MigrationFailure {
    fn from(error: Error) -> Self {
        Self {
            error,
            report: None,
        }
    }
}

impl From<relay_artifacts::Error> for MigrationFailure {
    fn from(error: relay_artifacts::Error) -> Self {
        Error::from(error).into()
    }
}

impl From<relay_store::Error> for MigrationFailure {
    fn from(error: relay_store::Error) -> Self {
        Error::from(error).into()
    }
}

fn migration_failure(message: &str, report: &Dict) -> MigrationFailure {
    MigrationFailure {
        error: Error::new(MIGRATION_ERROR, message),
        report: Some(report.clone()),
    }
}

/// `_required_text(value, field)`.
fn required_text(value: Option<&Value>, field: &str) -> Result<String> {
    optional_text(value).ok_or_else(|| artifact_error(format!("{field} is required")))
}

fn required_str(value: &str, field: &str) -> Result<String> {
    required_text(Some(&Value::Str(value.to_string())), field)
}

fn optional_str(value: Option<&str>) -> Option<String> {
    optional_text(value.map(|text| Value::Str(text.to_string())).as_ref())
}

/// `_normalize_provider(value)`: `codex`, `claude`, `None`, or an error.
pub(crate) fn normalize_provider(value: Option<&Value>) -> Result<Option<String>> {
    let text = super::str_or_empty(value);
    let text = json::py_strip(&text).to_lowercase();
    if text.is_empty() {
        return Ok(None);
    }
    if text.contains("codex") {
        return Ok(Some("codex".to_string()));
    }
    if text.contains("claude") {
        return Ok(Some("claude".to_string()));
    }
    Err(artifact_error(format!(
        "unsupported provider metadata: {}",
        repr(value.unwrap_or(&Value::Null))
    )))
}

fn normalize_provider_str(value: Option<&str>) -> Result<Option<String>> {
    normalize_provider(value.map(|text| Value::Str(text.to_string())).as_ref())
}

/// `_normalize_run_id(value)`.
pub(crate) fn normalize_run_id(value: Option<&Value>) -> Result<Option<i64>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Str(text)) if text.is_empty() => Ok(None),
        Some(value) => super::py_int(value)
            .map(Some)
            .map_err(|_| artifact_error("run_id must be an integer")),
    }
}

/// The arguments of `durable_program_event`.
#[derive(Clone, Debug, Default)]
pub struct DurableEvent<'a> {
    pub project_id: &'a str,
    pub stable_key: &'a str,
    pub node_kind: &'a str,
    pub capture_id: &'a str,
    pub entry_index: i64,
    pub summary: &'a str,
    pub details: Option<&'a str>,
    pub occurred_at: f64,
    pub source: &'a str,
    pub provider: Option<&'a str>,
    pub ticket_id: Option<&'a str>,
    pub run_id: Option<i64>,
    pub event_type: Option<&'a str>,
    pub risk_type: Option<&'a str>,
    pub status: Option<&'a str>,
}

fn text_or_null(value: Option<String>) -> Value {
    value.map_or(Value::Null, Value::Str)
}

/// `durable_program_event`: the only durable schema a project capture has.
pub fn durable_program_event(event: &DurableEvent<'_>) -> Result<Dict> {
    let Some(record_kind) = record_kind_for_node(event.node_kind) else {
        return Err(artifact_error(format!(
            "unsupported durable Program node kind: {}",
            json::str_repr(event.node_kind)
        )));
    };
    let stable_key = required_str(event.stable_key, "stable_key")?;
    let capture_id = required_str(event.capture_id, "capture_id")?;
    let summary = required_str(event.summary, "summary")?;
    let event_id = program_event_id(&stable_key)?;
    let mut attributes = Dict::new();
    if event.node_kind == NODE_PROGRAM_EVENT {
        attributes.insert(
            "event_type",
            optional_str(event.event_type).unwrap_or_else(|| "note".to_string()),
        );
    }
    if event.node_kind == NODE_RISK {
        attributes.insert(
            "risk_type",
            optional_str(event.risk_type).unwrap_or_else(|| "risk".to_string()),
        );
    }
    if event.node_kind == NODE_STATUS {
        attributes.insert(
            "status",
            optional_str(event.status).unwrap_or_else(|| summary.clone()),
        );
    }
    let mut document = Dict::new();
    document.insert("schema_version", PROGRAM_EVENT_SCHEMA_VERSION);
    document.insert("event_id", event_id);
    document.insert("project_id", required_str(event.project_id, "project_id")?);
    document.insert("record_kind", record_kind);
    document.insert("stable_key", stable_key);
    document.insert("capture_id", capture_id);
    document.insert("entry_index", event.entry_index);
    document.insert("summary", summary);
    document.insert("details", text_or_null(optional_str(event.details)));
    document.insert("occurred_at", Value::Float(event.occurred_at));
    document.insert(
        "capture_source",
        required_str(event.source, "capture_source")?,
    );
    document.insert(
        "provider",
        text_or_null(normalize_provider_str(event.provider)?),
    );
    let mut evidence = Dict::new();
    evidence.insert("ticket_id", text_or_null(optional_str(event.ticket_id)));
    evidence.insert("run_id", event.run_id.map_or(Value::Null, Value::Int));
    document.insert("evidence", evidence);
    document.insert("attributes", attributes);
    Ok(document)
}

/// `program_event_id(stable_key)`.
pub fn program_event_id(stable_key: &str) -> Result<String> {
    let stable_key = required_str(stable_key, "stable_key")?;
    let digest = hex_digest(stable_key.as_bytes());
    Ok(format!("program-{}", &digest[..40]))
}

/// `canonical_program_event(document)`: the event's committed bytes.
pub fn canonical_program_event(document: &Dict) -> Result<Vec<u8>> {
    validate_program_event(document)?;
    Ok((json::dumps_compact_sorted_unicode(&Value::Dict(document.clone())) + "\n").into_bytes())
}

/// `write_program_events`: publish immutable events, retrying only a
/// concurrent compare-and-swap race.
pub fn write_program_events(
    store: &ArtifactStore,
    documents: &[Dict],
    writer_event_id: &str,
    device_id: &str,
    actor_type: &str,
    provider: Option<&str>,
) -> Result<ProgramWriteResult> {
    let mut prepared = Vec::new();
    for document in documents {
        let event_id = super::str_or_empty(document.get("event_id"));
        prepared.push((event_id, canonical_program_event(document)?));
    }
    prepared.sort();
    let event_ids: Vec<String> = prepared.iter().map(|(id, _)| id.clone()).collect();
    if prepared.is_empty() {
        let snapshot = store.snapshot()?;
        return Ok(ProgramWriteResult {
            event_ids,
            commit_id: snapshot.commit_id,
            writer_event_id: writer_event_id.to_string(),
            idempotent: true,
        });
    }
    if event_ids.iter().collect::<BTreeSet<_>>().len() != prepared.len() {
        return Err(artifact_error(
            "Program event batch contains duplicate event IDs",
        ));
    }
    for attempt in 0..2 {
        let snapshot = store.snapshot()?;
        let mut operations = Vec::new();
        for (event_id, content) in &prepared {
            let path = format!("{EVENTS_PREFIX}{event_id}.json");
            match snapshot.file(&path) {
                Some(existing) if existing != content.as_slice() => {
                    return Err(Error::new(
                        "ArtifactEventCollision",
                        format!(
                            "immutable Program event {} already exists with different content",
                            json::str_repr(event_id)
                        ),
                    ));
                }
                Some(_) => {}
                None => operations.push(Operation::ProgramEventWrite {
                    event_id: event_id.clone(),
                    content: content.clone(),
                }),
            }
        }
        if operations.is_empty() {
            return Ok(ProgramWriteResult {
                event_ids,
                commit_id: snapshot.commit_id,
                writer_event_id: writer_event_id.to_string(),
                idempotent: true,
            });
        }
        let count = operations.len();
        let mut mutation = Mutation::new(writer_event_id, actor_type, device_id, operations);
        mutation.expected_base = Some(snapshot.commit_id.clone());
        mutation.provider = normalize_provider_str(provider)?;
        mutation.summary = format!("Publish {count} Program artifact event(s)");
        match store.mutate(&mutation) {
            Ok(result) => {
                return Ok(ProgramWriteResult {
                    event_ids,
                    commit_id: result.commit_id,
                    writer_event_id: writer_event_id.to_string(),
                    idempotent: result.idempotent,
                });
            }
            Err(error) if error.kind == ArtifactErrorKind::ConcurrentUpdate && attempt == 0 => {}
            Err(error) => return Err(error.into()),
        }
    }
    unreachable!("the second attempt returns")
}

/// `ingest_project_program_events`: project the canonical event files into
/// Graphify, failing on any ambiguity; returns how many were projected.
pub fn ingest_project_program_events(
    graph: &Graph<'_>,
    project: &Dict,
    repo_path: &str,
) -> Result<i64> {
    let repo = PathBuf::from(super::resolve_path(repo_path)?);
    let (artifact_project_id, event_files) = program_event_files(&repo)?;
    let mut seen_event_ids = BTreeSet::new();
    let mut seen_stable_keys = BTreeSet::new();
    let mut count = 0;
    for (artifact_path, content) in &event_files {
        let name = artifact_path.rsplit('/').next().unwrap_or(artifact_path);
        let text = relay_artifacts::pystr::decode_utf8(content).map_err(|error| {
            artifact_error(format!("malformed Program artifact {name}: {error}"))
        })?;
        let Some(parsed) = json::parse(text) else {
            return Err(artifact_error(format!(
                "malformed Program artifact {name}: Expecting value"
            )));
        };
        let Value::Dict(document) = parsed else {
            return Err(artifact_error(format!(
                "Program artifact {name} is not an object"
            )));
        };
        validate_program_event(&document)?;
        let event_id = super::get(&document, "event_id").py_str();
        let stable_key = super::get(&document, "stable_key").py_str();
        let stem = name.strip_suffix(".json").unwrap_or(name);
        if stem != event_id {
            return Err(artifact_error(format!(
                "Program artifact filename does not match event_id: {name}"
            )));
        }
        if !super::get(&document, "project_id").is_str(&artifact_project_id) {
            return Err(artifact_error(format!(
                "Program artifact {event_id} belongs to another project: {}",
                repr(&super::get(&document, "project_id"))
            )));
        }
        if seen_event_ids.contains(&event_id) || seen_stable_keys.contains(&stable_key) {
            return Err(artifact_error(format!(
                "duplicate Program artifact identity: {event_id}"
            )));
        }
        seen_event_ids.insert(event_id);
        seen_stable_keys.insert(stable_key);
        project_program_event(graph, project, &repo, &document)?;
        count += 1;
    }
    // Query only capture kinds: decoding every ticket and run node of the
    // project made each board-change ingest slower (RR-471).
    let project_id = super::get(project, "id").py_str();
    for kind in PROJECT_CAPTURE_KINDS {
        for node in graph.nodes(Some(kind), Some(&project_id))? {
            let body = dict_or_empty(&node, "body");
            if optional_text(body.get("durable_event_id")).is_some()
                && !seen_stable_keys.contains(&super::get(&node, "stable_key").py_str())
            {
                graph.delete_node(&super::get(&node, "id").py_str())?;
            }
        }
    }
    Ok(count)
}

/// `export_graphify_project_captures`: export one project's legacy
/// capture-only nodes, with a resumable journal. `failure_injector` is the
/// test hook called after the named stages.
pub fn export_graphify_project_captures(
    graph_store: &GraphifyStore,
    artifact_store: &ArtifactStore,
    state_root: &Path,
    device_id: &str,
    provider: Option<&str>,
    failure_injector: Option<&FailureInjector>,
) -> std::result::Result<Dict, MigrationFailure> {
    let repo = artifact_store.repo_path.clone();
    let repo_text = repo.to_string_lossy().into_owned();
    let project =
        graph_store.with(|graph| graph.find_node(NODE_PROJECT, &format!("repo:{repo_text}")))?;
    let state_root = PathBuf::from(relay_artifacts::paths::resolve(
        &state_root.to_string_lossy(),
    ));
    let migration_root = state_root
        .join("artifacts")
        .join(&artifact_store.project_id)
        .join("program-migration");
    fs::create_dir_all(&migration_root).map_err(Error::from)?;
    let report_path = migration_root.join("report.json");
    let journal_path = migration_root.join("journal.json");
    let backup_path = migration_root.join("graphify-pre-export.db");
    let manifest_path = migration_root.join("pre-export-manifest.json");

    let mut report = Dict::new();
    report.insert("schema_version", PROGRAM_EXPORT_SCHEMA_VERSION);
    report.insert("project_id", artifact_store.project_id.as_str());
    report.insert("repo_path", repo_text.as_str());
    report.insert("status", "review_required");
    report.insert("issues", Value::List(Vec::new()));
    report.insert("records", 0i64);
    let Some(project) = project else {
        issue(
            &mut report,
            "missing_project",
            "Graphify has no project node for the registered repository",
        );
        write_json(&report_path, &report)?;
        return Err(migration_failure("Program export requires review", &report));
    };
    let project_node_id = super::get(&project, "id");

    let mut documents: Vec<Dict> = Vec::new();
    let mut identities: BTreeSet<(String, i64)> = BTreeSet::new();
    let nodes = graph_store.with(|graph| graph.nodes(None, None))?;
    for node in nodes {
        let kind = super::get(&node, "kind").py_str();
        if !PROJECT_CAPTURE_KINDS.contains(&kind.as_str()) {
            continue;
        }
        let node_id = super::get(&node, "id").py_str();
        let body = dict_or_empty(&node, "body");
        let evidence = dict_or_empty(&body, "evidence");
        let evidence_repo = resolved_optional_path(evidence.get("repo_path"))?;
        let belongs = json::py_eq(&super::get(&node, "project_id"), &project_node_id);
        let references_repo = evidence_repo.as_deref() == Some(repo_text.as_str());
        if !belongs && !references_repo {
            if matches!(node.get("project_id"), None | Some(Value::Null)) && evidence_repo.is_none()
            {
                issue(
                    &mut report,
                    "orphaned_capture",
                    &format!("{node_id} has no confirmed project identity"),
                );
            }
            continue;
        }
        if !belongs
            || evidence_repo
                .as_ref()
                .is_some_and(|path| *path != repo_text)
        {
            issue(
                &mut report,
                "cross_project_capture",
                &format!("{node_id} has conflicting project evidence"),
            );
            continue;
        }
        let document = match document_from_legacy_node(&node, &artifact_store.project_id) {
            Ok(document) => document,
            Err(error)
                if matches!(
                    error.class,
                    PROGRAM_ARTIFACT_ERROR | "TypeError" | "ValueError"
                ) =>
            {
                issue(
                    &mut report,
                    "malformed_capture",
                    &format!("{node_id}: {}", error.message),
                );
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        let identity = (
            super::get(&document, "capture_id").py_str(),
            super::get(&document, "entry_index").py_int().unwrap_or(0),
        );
        if identities.contains(&identity) {
            issue(
                &mut report,
                "duplicate_capture",
                &format!("duplicate capture identity {}:{}", identity.0, identity.1),
            );
            continue;
        }
        identities.insert(identity);
        documents.push(document);
    }

    report.insert("records", documents.len() as i64);
    let manifest = document_manifest(&documents)?;
    write_json(&manifest_path, &manifest)?;
    let manifest_sha256 = json_digest(&Value::Dict(manifest.clone()));
    report.insert("manifest_sha256", manifest_sha256.as_str());
    write_json(&report_path, &report)?;
    if has_issues(&report) {
        return Err(migration_failure("Program export requires review", &report));
    }

    if graph_store.path() != Path::new(":memory:") && !backup_path.exists() {
        graph_store.backup(&backup_path)?;
    }
    let mut journal = load_json(&journal_path);
    let prior_manifest = optional_text(journal.get("manifest_sha256"));
    if prior_manifest.is_some_and(|prior| prior != manifest_sha256) {
        issue(
            &mut report,
            "event_id_reconciliation_required",
            "capture manifest changed after migration journaling began",
        );
        write_json(&report_path, &report)?;
        return Err(migration_failure(
            "Program captures changed during export; explicit reconciliation is required",
            &report,
        ));
    }
    let backup_value = || {
        if backup_path.exists() {
            Value::Str(backup_path.to_string_lossy().into_owned())
        } else {
            Value::Null
        }
    };
    journal.insert("schema_version", PROGRAM_EXPORT_SCHEMA_VERSION);
    journal.insert("project_id", artifact_store.project_id.as_str());
    journal.insert("repo_path", repo_text.as_str());
    journal.insert("manifest_sha256", manifest_sha256.as_str());
    journal.insert("backup_path", backup_value());
    journal.insert("stage", "validated");
    write_json(&journal_path, &journal)?;
    if let Some(inject) = failure_injector {
        inject("after_manifest")?;
    }

    let writer_event_id = format!("program-export:{}", &manifest_sha256[..40]);
    let result = match write_program_events(
        artifact_store,
        &documents,
        &writer_event_id,
        device_id,
        "migration",
        provider,
    ) {
        Ok(result) => result,
        Err(error)
            if matches!(
                error.class,
                "ArtifactValidationError" | "ArtifactEventCollision" | PROGRAM_ARTIFACT_ERROR
            ) =>
        {
            issue(&mut report, "artifact_validation_failed", &error.message);
            journal.insert("stage", "review_required");
            journal.insert("error", error.message.as_str());
            write_json(&journal_path, &journal)?;
            write_json(&report_path, &report)?;
            return Err(migration_failure(
                "Program export failed artifact validation; review is required",
                &report,
            ));
        }
        Err(error) => return Err(error.into()),
    };
    journal.insert("stage", "exported");
    journal.insert("artifact_commit", result.commit_id.as_str());
    write_json(&journal_path, &journal)?;
    if let Some(inject) = failure_injector {
        inject("after_artifact_commit")?;
    }

    let actual = artifact_manifest(artifact_store, &documents)?;
    if !json::py_eq(&Value::Dict(actual.clone()), &Value::Dict(manifest.clone())) {
        let mut mismatch = Dict::new();
        mismatch.insert("kind", "manifest_mismatch");
        mismatch.insert("detail", "artifact events differ from pre-export manifest");
        report.insert("issues", Value::List(vec![Value::Dict(mismatch)]));
        write_json(&report_path, &report)?;
        return Err(migration_failure(
            "Program export manifest mismatch",
            &report,
        ));
    }
    let post_manifest = json_digest(&Value::Dict(actual));
    journal.insert("stage", "verified");
    journal.insert("post_manifest_sha256", post_manifest.as_str());
    write_json(&journal_path, &journal)?;
    report.insert("status", "verified");
    report.insert("artifact_commit", result.commit_id.as_str());
    report.insert("writer_event_id", writer_event_id.as_str());
    report.insert("idempotent", result.idempotent);
    report.insert("post_manifest_sha256", post_manifest.as_str());
    report.insert("backup_path", backup_value());
    report.insert("journal_path", journal_path.to_string_lossy().into_owned());
    write_json(&report_path, &report)?;
    Ok(report)
}

/// `replace_graphify_with_clean_rebuild`: build a fresh projection beside
/// `graphify_path` and replace the old database only once it reproduces the
/// durable capture manifest.
pub fn replace_graphify_with_clean_rebuild(
    graphify_path: &Path,
    registry_path: &Path,
    runs_db_path: Option<&Path>,
    expected_capture_manifest: &Dict,
    backup_path: &Path,
) -> Result<Dict> {
    if graphify_path.exists() && !backup_path.exists() {
        GraphifyStore::open(graphify_path)?.backup(backup_path)?;
    }
    let name = graphify_path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let temporary = graphify_path.with_file_name(format!(".{name}.rebuild-{}", random_hex()));
    let suffixed = |path: &Path, suffix: &str| {
        let mut text = path.as_os_str().to_os_string();
        text.push(suffix);
        PathBuf::from(text)
    };
    let outcome = (|| -> Result<Dict> {
        let (counts, actual) = {
            let rebuilt = GraphifyStore::open(&temporary)?;
            let counts = super::ingest::ingest_registered_projects(
                &rebuilt,
                &super::ingest::IngestOptions {
                    registry_path: registry_path.to_path_buf(),
                    runs_db_path: runs_db_path.map(Path::to_path_buf),
                    index_files: true,
                    ..Default::default()
                },
            )?;
            let actual = graph_capture_manifest(&rebuilt)?;
            (counts, actual)
        };
        if !json::py_eq(
            &Value::Dict(actual.clone()),
            &Value::Dict(expected_capture_manifest.clone()),
        ) {
            return Err(artifact_error(
                "clean Graphify rebuild did not reproduce the durable capture manifest",
            ));
        }
        fs::rename(&temporary, graphify_path)?;
        for suffix in ["-wal", "-shm"] {
            let _ = fs::remove_file(suffixed(graphify_path, suffix));
        }
        let mut result = Dict::new();
        result.insert("counts", counts);
        result.insert("capture_manifest", actual);
        result.insert("backup_path", backup_path.to_string_lossy().into_owned());
        Ok(result)
    })();
    let _ = fs::remove_file(&temporary);
    let _ = fs::remove_file(suffixed(&temporary, "-wal"));
    let _ = fs::remove_file(suffixed(&temporary, "-shm"));
    outcome
}

/// `graph_capture_manifest`: each durable capture node's digest by event id.
pub fn graph_capture_manifest(store: &GraphifyStore) -> Result<Dict> {
    let mut manifest = BTreeMap::new();
    for node in store.with(|graph| graph.nodes(None, None))? {
        let kind = super::get(&node, "kind");
        if !PROJECT_CAPTURE_KINDS.contains(&kind.py_str().as_str()) {
            continue;
        }
        let body = super::get(&node, "body");
        let durable_id =
            optional_text(body.as_dict().and_then(|body| body.get("durable_event_id")));
        if let Some(durable_id) = durable_id {
            let mut projection = Dict::new();
            projection.insert("kind", kind);
            projection.insert("stable_key", super::get(&node, "stable_key"));
            projection.insert("title", super::get(&node, "title"));
            projection.insert("body", body);
            manifest.insert(durable_id, json_digest(&Value::Dict(projection)));
        }
    }
    Ok(string_map(manifest))
}

/// `expected_graph_manifest(documents)`.
pub fn expected_graph_manifest(documents: &[Dict]) -> Result<Dict> {
    let mut manifest = BTreeMap::new();
    for document in documents {
        let projection = projection_for_document(document)?;
        manifest.insert(
            super::get(document, "event_id").py_str(),
            json_digest(&Value::Dict(projection)),
        );
    }
    Ok(string_map(manifest))
}

fn string_map(map: BTreeMap<String, String>) -> Dict {
    let mut dict = Dict::new();
    for (key, value) in map {
        dict.insert(&key, value);
    }
    dict
}

/// `_project_program_event`.
fn project_program_event(
    graph: &Graph<'_>,
    project: &Dict,
    repo: &Path,
    document: &Dict,
) -> Result<()> {
    let projection = projection_for_document(document)?;
    let project_id = super::get(project, "id").py_str();
    let kind = super::get(&projection, "kind").py_str();
    let body = dict_or_empty(&projection, "body");
    let title = super::get(&projection, "title").py_str();
    let node = graph.upsert_node(
        &kind,
        &super::get(&projection, "stable_key").py_str(),
        Some(&project_id),
        Some(&title),
        Some(&body),
        None,
    )?;
    let node_id = super::get(&node, "id").py_str();
    let mut edge_body = Dict::new();
    edge_body.insert("source", "program_artifact");
    edge_body.insert("event_id", super::get(document, "event_id"));
    graph.upsert_edge(&node_id, &project_id, EDGE_BELONGS_TO, Some(&edge_body))?;
    graph.upsert_edge(&project_id, &node_id, EDGE_CONTAINS, Some(&edge_body))?;
    let evidence = dict_or_empty(document, "evidence");
    if let Some(ticket_id) = optional_text(evidence.get("ticket_id")) {
        let stable_key = format!("repo:{}:{ticket_id}", repo.to_string_lossy());
        if let Some(ticket) = graph.find_node(NODE_TICKET, &stable_key)? {
            let ticket_node_id = super::get(&ticket, "id").py_str();
            graph.upsert_edge(&node_id, &ticket_node_id, EDGE_RELATED_TO, Some(&edge_body))?;
            if super::get(&node, "kind").is_str(NODE_RISK)
                && body
                    .get("risk_type")
                    .is_some_and(|value| value.is_str("blocker"))
            {
                graph.upsert_edge(&node_id, &ticket_node_id, EDGE_BLOCKS, Some(&edge_body))?;
            }
        }
    }
    if let Some(run_id) = normalize_run_id(evidence.get("run_id"))?
        && let Some(run) = graph.find_node(NODE_RUN, &format!("run:{run_id}"))?
        && json::py_eq(&super::get(&run, "project_id"), &super::get(project, "id"))
    {
        let run_node_id = super::get(&run, "id").py_str();
        graph.upsert_edge(&node_id, &run_node_id, EDGE_RELATED_TO, Some(&edge_body))?;
    }
    Ok(())
}

/// `_projection_for_document`: the Graphify node an event projects to.
fn projection_for_document(document: &Dict) -> Result<Dict> {
    validate_program_event(document)?;
    let record_kind = super::get(document, "record_kind").py_str();
    let kind = node_kind_for_record(&record_kind).unwrap_or_default();
    let attributes = dict_or_empty(document, "attributes");
    let mut body = Dict::new();
    body.insert("durable_event_id", super::get(document, "event_id"));
    body.insert("artifact_project_id", super::get(document, "project_id"));
    body.insert("schema_version", super::get(document, "schema_version"));
    body.insert("capture_id", super::get(document, "capture_id"));
    body.insert("entry_index", super::get(document, "entry_index"));
    body.insert("capture_source", super::get(document, "capture_source"));
    body.insert("summary", super::get(document, "summary"));
    body.insert("details", super::get(document, "details"));
    body.insert("provider_key", super::get(document, "provider"));
    body.insert("occurred_at", super::get(document, "occurred_at"));
    body.insert(
        "evidence",
        match document.get("evidence") {
            Some(evidence) if evidence.truthy() => evidence.clone(),
            _ => Value::Dict(Dict::new()),
        },
    );
    body.update(&attributes);
    let mut projection = Dict::new();
    projection.insert("kind", kind);
    projection.insert("stable_key", super::get(document, "stable_key"));
    projection.insert("title", super::get(document, "summary"));
    projection.insert("body", body);
    Ok(projection)
}

/// `_document_from_legacy_node`, evaluating its arguments in Python's order.
fn document_from_legacy_node(node: &Dict, project_id: &str) -> Result<Dict> {
    let Some(body) = node.get("body").and_then(Value::as_dict) else {
        return Err(artifact_error("body is not an object"));
    };
    let capture_id = required_text(body.get("capture_id"), "capture_id")?;
    let entry_index = super::py_int(&super::get(body, "entry_index"))?;
    let evidence = dict_or_empty(body, "evidence");
    let stable_key = required_text(node.get("stable_key"), "stable_key")?;
    let node_kind = required_text(node.get("kind"), "kind")?;
    let summary_value = match node.get("title") {
        Some(title) if title.truthy() => title.clone(),
        _ => super::get(body, "summary"),
    };
    let summary = required_text(Some(&summary_value), "summary")?;
    let details = optional_text(body.get("details"));
    let occurred_at = super::py_float(&super::get(body, "occurred_at"))?;
    let source_value = match body.get("capture_source") {
        Some(source) if source.truthy() => source.clone(),
        _ => Value::Str("session_capture".to_string()),
    };
    let source = required_text(Some(&source_value), "capture_source")?;
    let provider = optional_text(body.get("provider_key"));
    let ticket_id = optional_text(evidence.get("ticket_id"));
    let run_id = normalize_run_id(evidence.get("run_id"))?;
    let event_type = optional_text(body.get("event_type"));
    let risk_type = optional_text(body.get("risk_type"));
    let status = optional_text(body.get("status"));
    durable_program_event(&DurableEvent {
        project_id,
        stable_key: &stable_key,
        node_kind: &node_kind,
        capture_id: &capture_id,
        entry_index,
        summary: &summary,
        details: details.as_deref(),
        occurred_at,
        source: &source,
        provider: provider.as_deref(),
        ticket_id: ticket_id.as_deref(),
        run_id,
        event_type: event_type.as_deref(),
        risk_type: risk_type.as_deref(),
        status: status.as_deref(),
    })
}

fn is_nonnegative_integer(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Int(number)) => *number >= 0,
        Some(Value::BigInt(digits)) => !digits.starts_with('-'),
        _ => false,
    }
}

fn is_finite_number(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Int(_)) => true,
        Some(Value::BigInt(digits)) => digits.parse::<f64>().is_ok_and(f64::is_finite),
        Some(Value::Float(number)) => number.is_finite(),
        _ => false,
    }
}

fn only_keys(value: Option<&Value>, allowed: &[&str]) -> bool {
    value
        .and_then(Value::as_dict)
        .is_some_and(|dict| dict.iter().all(|(key, _)| allowed.contains(&key)))
}

/// `_validate_program_event`.
pub fn validate_program_event(document: &Dict) -> Result<()> {
    if !json::py_eq(
        &super::get(document, "schema_version"),
        &Value::Int(PROGRAM_EVENT_SCHEMA_VERSION),
    ) {
        return Err(artifact_error(
            "Program event schema_version is unsupported",
        ));
    }
    let event_id = required_text(document.get("event_id"), "event_id")?;
    let stable_key = required_text(document.get("stable_key"), "stable_key")?;
    if event_id != program_event_id(&stable_key)? {
        return Err(artifact_error("Program event_id does not match stable_key"));
    }
    required_text(document.get("project_id"), "project_id")?;
    let record_kind = required_text(document.get("record_kind"), "record_kind")?;
    if node_kind_for_record(&record_kind).is_none() {
        return Err(artifact_error(format!(
            "unsupported Program record_kind: {}",
            json::str_repr(&record_kind)
        )));
    }
    required_text(document.get("capture_id"), "capture_id")?;
    if !is_nonnegative_integer(document.get("entry_index")) {
        return Err(artifact_error(
            "Program event entry_index must be a non-negative integer",
        ));
    }
    required_text(document.get("summary"), "summary")?;
    required_text(document.get("capture_source"), "capture_source")?;
    if !is_finite_number(document.get("occurred_at")) {
        return Err(artifact_error("Program event occurred_at must be numeric"));
    }
    let provider = super::get(document, "provider");
    if !(matches!(provider, Value::Null) || provider.is_str("codex") || provider.is_str("claude")) {
        return Err(artifact_error(format!(
            "unsupported provider metadata: {}",
            repr(&provider)
        )));
    }
    if !only_keys(document.get("evidence"), &["ticket_id", "run_id"]) {
        return Err(artifact_error(
            "Program event evidence has unsupported fields",
        ));
    }
    if !only_keys(
        document.get("attributes"),
        &["event_type", "risk_type", "status"],
    ) {
        return Err(artifact_error(
            "Program event attributes has unsupported fields",
        ));
    }
    const ALLOWED: [&str; 14] = [
        "schema_version",
        "event_id",
        "project_id",
        "record_kind",
        "stable_key",
        "capture_id",
        "entry_index",
        "summary",
        "details",
        "occurred_at",
        "capture_source",
        "provider",
        "evidence",
        "attributes",
    ];
    let unknown: BTreeSet<&str> = document
        .iter()
        .map(|(key, _)| key)
        .filter(|key| !ALLOWED.contains(key))
        .collect();
    if !unknown.is_empty() {
        return Err(artifact_error(format!(
            "Program event contains unsupported fields: {}",
            unknown.into_iter().collect::<Vec<_>>().join(", ")
        )));
    }
    Ok(())
}

/// `_program_event_files`: the artifact project id and every event file on
/// the artifact ref, or `("", {})` for a project without one.
fn program_event_files(repo: &Path) -> Result<(String, BTreeMap<String, Vec<u8>>)> {
    let head = git(repo, &["rev-parse", "--verify", ARTIFACT_REF], None);
    if !head.ok() {
        let local_events = repo.join(".orchestrator/program/events");
        let local_config = repo.join(".orchestrator/config.toml");
        let artifact_configured = fs::read_to_string(&local_config)
            .ok()
            .and_then(|text| relay_artifacts::toml::loads(&text).ok())
            .is_some_and(|document| {
                matches!(
                    document.get("artifact_ref"),
                    Some(relay_artifacts::toml::Value::String(value)) if value == ARTIFACT_REF
                )
            });
        if local_events.exists() || artifact_configured {
            return Err(artifact_error(
                "configured Program artifact authority is missing refs/heads/relay/artifacts",
            ));
        }
        return Ok((String::new(), BTreeMap::new()));
    }
    let config = git_bytes(
        repo,
        &["show", &format!("{ARTIFACT_REF}:.orchestrator/config.toml")],
    )?;
    let project_id = artifact_project_id(&config)?;
    let listing = git_text(
        repo,
        &[
            "ls-tree",
            "-r",
            "--name-only",
            ARTIFACT_REF,
            "--",
            ".orchestrator/program/events",
        ],
    )?;
    let mut files = BTreeMap::new();
    for path in relay_artifacts::pystr::splitlines(&listing) {
        let relative = path.strip_prefix(EVENTS_PREFIX).unwrap_or(path);
        if !path.starts_with(EVENTS_PREFIX) || !path.ends_with(".json") || relative.contains('/') {
            return Err(artifact_error(format!(
                "unsupported Program artifact path: {path}"
            )));
        }
        let content = git_bytes(repo, &["show", &format!("{ARTIFACT_REF}:{path}")])?;
        files.insert(path.to_string(), content);
    }
    Ok((project_id, files))
}

/// `_artifact_project_id(config)`.
fn artifact_project_id(config: &[u8]) -> Result<String> {
    let document = relay_artifacts::pystr::decode_utf8(config)
        .and_then(relay_artifacts::toml::loads)
        .map_err(|error| {
            artifact_error(format!(
                "Program artifacts have no valid project config: {error}"
            ))
        })?;
    let project_id = match document.get("project_id") {
        Some(relay_artifacts::toml::Value::String(text)) => Some(Value::Str(text.clone())),
        Some(relay_artifacts::toml::Value::Integer(number)) => Some(Value::Int(*number)),
        Some(relay_artifacts::toml::Value::Boolean(flag)) => Some(Value::Bool(*flag)),
        Some(relay_artifacts::toml::Value::Float(number)) => Some(Value::Float(*number)),
        Some(_) => Some(Value::Str("<value>".to_string())),
        None => None,
    };
    required_text(project_id.as_ref(), "project_id")
}

/// `_git(repo, …)`: stripped text output, or a `ProgramArtifactError`.
fn git_text(repo: &Path, arguments: &[&str]) -> Result<String> {
    let output = git(repo, arguments, None);
    if !output.ok() {
        return Err(artifact_error(format!(
            "Git artifact read failed ({}): {}",
            arguments.join(" "),
            json::py_strip(&output.stderr_text())
        )));
    }
    Ok(json::py_strip(&output.text()).to_string())
}

/// `_git_bytes(repo, …)`.
fn git_bytes(repo: &Path, arguments: &[&str]) -> Result<Vec<u8>> {
    let output = git(repo, arguments, None);
    if !output.ok() {
        return Err(artifact_error(format!(
            "Git artifact read failed ({}): {}",
            arguments.join(" "),
            json::py_strip(&String::from_utf8_lossy(&output.stderr))
        )));
    }
    Ok(output.stdout)
}

/// `_document_manifest(documents)`.
fn document_manifest(documents: &[Dict]) -> Result<Dict> {
    let mut manifest = BTreeMap::new();
    for document in documents {
        manifest.insert(
            super::get(document, "event_id").py_str(),
            hex_digest(&canonical_program_event(document)?),
        );
    }
    Ok(string_map(manifest))
}

/// `_artifact_manifest(store, documents)`.
fn artifact_manifest(store: &ArtifactStore, documents: &[Dict]) -> Result<Dict> {
    let snapshot = store.snapshot()?;
    let mut manifest = BTreeMap::new();
    for document in documents {
        let event_id = super::get(document, "event_id").py_str();
        if let Some(content) = snapshot.file(&format!("{EVENTS_PREFIX}{event_id}.json")) {
            manifest.insert(event_id, hex_digest(content));
        }
    }
    Ok(string_map(manifest))
}

fn has_issues(report: &Dict) -> bool {
    report.get("issues").is_some_and(Value::truthy)
}

/// `_issue(report, kind, detail)`.
fn issue(report: &mut Dict, kind: &str, detail: &str) {
    let mut issues = report
        .get("issues")
        .and_then(Value::as_list)
        .map(<[Value]>::to_vec)
        .unwrap_or_default();
    if issues.len() < MAX_REPORT_ISSUES {
        let mut entry = Dict::new();
        entry.insert("kind", kind);
        entry.insert("detail", detail);
        issues.push(Value::Dict(entry));
    }
    report.insert("issues", Value::List(issues));
}

/// `_load_json(path)`: the object, or `{}`.
fn load_json(path: &Path) -> Dict {
    fs::read_to_string(path)
        .ok()
        .and_then(|text| json::parse(&text))
        .and_then(|value| match value {
            Value::Dict(dict) => Some(dict),
            _ => None,
        })
        .unwrap_or_default()
}

/// `_write_json(path, value)`: sorted, indented, owner-only, atomic.
fn write_json(path: &Path, value: &Dict) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let temporary = path.with_file_name(format!(".{name}.{}.tmp", random_hex()));
    let text = relay_store::sql::dumps_indent(&sorted_keys(&Value::Dict(value.clone()))) + "\n";
    fs::write(&temporary, text)?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    fs::rename(&temporary, path)?;
    Ok(())
}

/// `_json_digest(value)`.
pub(crate) fn json_digest(value: &Value) -> String {
    hex_digest(json::dumps_compact_sorted_unicode(value).as_bytes())
}

/// `_resolved_optional_path(value)`.
fn resolved_optional_path(value: Option<&Value>) -> Result<Option<String>> {
    optional_text(value)
        .map(|text| super::resolve_path(&text))
        .transpose()
}
