//! `services/artifact_lifecycle.py`: the artifact-backed worker lifecycle.
//!
//! One `ArtifactLifecycleCoordinator` per project owns every lifecycle write
//! a run makes on `refs/heads/relay/artifacts`: the claim and the read-only
//! worker snapshot with its proof file, the structured outcome (and one
//! superseding post), review leases, failures, spike results, merge
//! conflicts, the reviewed `done` or `verification_blocked` publication, the
//! verification-only close-out and dependency promotion.
//!
//! Everything it leaves behind is the Python module's own form, so a Python
//! and a Rust daemon can take turns on one data root in the middle of a run:
//! the commits (event IDs, summaries, ticket rewrites and run-log lines), the
//! outcome files under `<project state>/lifecycle/outcomes/`, the snapshot
//! proofs under `lifecycle/snapshot-proofs/`, the snapshot tree in the
//! worker's worktree (files `0444`, directories `0555`) and its
//! `.artifact-snapshot.json` manifest, and the snapshot leases shared with
//! `retention`. Codex and Claude runs go through the same code; the provider
//! is only validated and recorded.
//!
//! Known differences, each refused the same way as in Python:
//!
//! - A corrupt outcome, manifest, proof or registry file is reported without
//!   Python's JSON decode position, as everywhere in this crate.
//! - An `OSError` is described as `[Errno N] <message>: '<path>'` with the
//!   path this module was reading, which is Python's form for the common
//!   cases (a missing or unreadable file).

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, LazyLock, Mutex};

use relay_intents::json::{self, Dict, Value, py_eq, py_eq_optional};
use relay_intents::sha256::hex_digest;

use crate::instant::Instant;
use crate::retention::{
    ArtifactRetentionManager, LeaseRequest, RetentionOptions, SnapshotLease, SnapshotLeaseStore,
};
use crate::store::{self, ArtifactStore, Mutation, Operation, Snapshot};
use crate::{Error, ErrorKind, Result, paths, pystr, toml};

pub const OUTCOME_SCHEMA_VERSION: i64 = 1;
pub const SNAPSHOT_SCHEMA_VERSION: i64 = 1;
pub const MAX_SUMMARY_BYTES: usize = 4 * 1024;
pub const MAX_VERIFICATION_BYTES: usize = 8 * 1024;
pub const MAX_CHANGED_PATHS: usize = 500;
pub const MAX_LOCAL_LOG_BYTES: u64 = 2 * 1024 * 1024;
pub const TERMINAL_RUN_STATES: [&str; 5] = [
    "Canceled",
    "Failed",
    "Merged",
    "VerificationBlocked",
    "SpikeCompleted",
];
pub const LIVE_RUN_STATES: [&str; 8] = [
    "Claimed",
    "Running",
    "SpikeResultReady",
    "AwaitingReview",
    "Reviewing",
    "Succeeded",
    "MergeConflict",
    "IntegrationBlocked",
];

const OUTCOME_KEYS: [&str; 12] = [
    "schema_version",
    "project_id",
    "ticket_id",
    "run_id",
    "provider",
    "status",
    "summary",
    "changed_paths",
    "verification",
    "source_commit",
    "verification_blocker",
    "verification_resume",
];

const SIZING_KEYS: [&str; 4] = [
    "worker_model",
    "worker_effort",
    "worker_sizing_rationale",
    "worker_provider_notes",
];

const SNAPSHOT_MANIFEST: &str = ".orchestrator/.artifact-snapshot.json";
const ARCHIVE_INDEX: &str = ".orchestrator/archive-index.jsonl";

fn validation(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::Validation, message)
}

/// `WorkerOutcomeStatus`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkerOutcomeStatus {
    Completed,
    VerificationBlocked,
}

impl WorkerOutcomeStatus {
    pub fn value(self) -> &'static str {
        match self {
            WorkerOutcomeStatus::Completed => "completed",
            WorkerOutcomeStatus::VerificationBlocked => "verification_blocked",
        }
    }

    /// `WorkerOutcomeStatus(value)`; `None` where Python raises `ValueError`.
    pub fn from_value(value: &str) -> Option<Self> {
        match value {
            "completed" => Some(WorkerOutcomeStatus::Completed),
            "verification_blocked" => Some(WorkerOutcomeStatus::VerificationBlocked),
            _ => None,
        }
    }
}

/// `StructuredWorkerOutcome`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StructuredWorkerOutcome {
    pub schema_version: i64,
    pub project_id: String,
    pub ticket_id: String,
    pub run_id: i64,
    pub provider: String,
    pub status: WorkerOutcomeStatus,
    pub summary: String,
    pub changed_paths: Vec<String>,
    pub verification: Vec<String>,
    pub source_commit: String,
    pub verification_blocker: Option<String>,
    pub verification_resume: Option<String>,
}

impl StructuredWorkerOutcome {
    /// `_outcome_json`: the outcome as the JSON object stored on disk.
    pub fn to_json(&self) -> Dict {
        let mut value = Dict::new();
        value.insert("schema_version", self.schema_version);
        value.insert("project_id", self.project_id.as_str());
        value.insert("ticket_id", self.ticket_id.as_str());
        value.insert("run_id", self.run_id);
        value.insert("provider", self.provider.as_str());
        value.insert("status", self.status.value());
        value.insert("summary", self.summary.as_str());
        value.insert("changed_paths", strings(&self.changed_paths));
        value.insert("verification", strings(&self.verification));
        value.insert("source_commit", self.source_commit.as_str());
        value.insert("verification_blocker", optional(&self.verification_blocker));
        value.insert("verification_resume", optional(&self.verification_resume));
        value
    }
}

/// `ArtifactWorkerSnapshot`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArtifactWorkerSnapshot {
    pub project_id: String,
    pub ticket_id: String,
    pub artifact_id: String,
    pub artifact_head: String,
    pub run_id: i64,
    pub provider: String,
    pub lease_id: String,
    pub manifest_path: PathBuf,
    pub files: Vec<String>,
}

/// `LifecycleWriteResult`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LifecycleWriteResult {
    pub event_id: String,
    pub commit_id: String,
    pub promoted_ticket_ids: Vec<String>,
    pub idempotent: bool,
}

impl LifecycleWriteResult {
    fn new(event_id: &str, commit_id: &str, idempotent: bool) -> Self {
        Self {
            event_id: event_id.to_string(),
            commit_id: commit_id.to_string(),
            promoted_ticket_ids: Vec::new(),
            idempotent,
        }
    }
}

/// `ScopeValidation`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScopeValidation {
    pub project_id: String,
    pub repository_path: String,
    pub registry_schema_version: i64,
}

/// A failure, as `record_failure`'s `canceled` and `retry` flags choose it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FailureKind {
    pub canceled: bool,
    pub retry: bool,
}

/// A ticket's front matter as `_split_ticket` reads it: every `key: value`
/// line, a repeated key keeping its last value.
pub type TicketFields = HashMap<String, String>;

type Candidate = (String, Vec<u8>, TicketFields, Vec<String>);

struct CandidateCache {
    head: String,
    statuses: HashMap<String, String>,
    candidates: Arc<Vec<Candidate>>,
}

/// One ordered set of front-matter updates; `None` removes the key.
type Updates = Vec<(String, Option<String>)>;

fn set(updates: &mut Updates, key: &str, value: Option<String>) {
    match updates.iter_mut().find(|(name, _)| name == key) {
        Some(entry) => entry.1 = value,
        None => updates.push((key.to_string(), value)),
    }
}

fn updates(pairs: &[(&str, Option<String>)]) -> Updates {
    let mut result = Updates::new();
    for (key, value) in pairs {
        set(&mut result, key, value.clone());
    }
    result
}

fn some(value: impl Into<String>) -> Option<String> {
    Some(value.into())
}

/// `ArtifactLifecycleCoordinator`: one project's lifecycle facade over the
/// canonical artifact writer.
pub struct ArtifactLifecycleCoordinator {
    pub store: ArtifactStore,
    pub registry_path: PathBuf,
    pub device_id: String,
    pub leases: SnapshotLeaseStore,
    pub lifecycle_root: PathBuf,
    pub outcome_root: PathBuf,
    pub snapshot_proof_root: PathBuf,
    now: Box<dyn Fn() -> Instant + Send + Sync>,
    dependent_candidates: Mutex<Option<CandidateCache>>,
}

impl ArtifactLifecycleCoordinator {
    /// The coordinator for `store`; `now` defaults to the system clock.
    pub fn new(
        store: ArtifactStore,
        registry_path: &Path,
        device_id: &str,
        now: Option<Box<dyn Fn() -> Instant + Send + Sync>>,
    ) -> Result<Self> {
        let device_id = safe_id(device_id, "device ID")?.to_string();
        let lifecycle_root = store.project_state.join("lifecycle");
        Ok(Self {
            leases: SnapshotLeaseStore::new(&store),
            outcome_root: lifecycle_root.join("outcomes"),
            snapshot_proof_root: lifecycle_root.join("snapshot-proofs"),
            lifecycle_root,
            registry_path: registry_path.to_path_buf(),
            device_id,
            now: now.unwrap_or_else(|| Box::new(Instant::now)),
            store,
            dependent_candidates: Mutex::new(None),
        })
    }

    fn now(&self) -> Instant {
        (self.now)()
    }

    fn instant(&self) -> String {
        format_instant(self.now())
    }

    /// `is_enabled`: whether the board's config turns the lifecycle on.
    pub fn is_enabled(store: &ArtifactStore) -> Result<bool> {
        let snapshot = store.snapshot()?;
        let content = snapshot
            .file(".orchestrator/config.toml")
            .ok_or_else(|| Error::new(ErrorKind::Store, "'.orchestrator/config.toml'"))?;
        let config = toml::loads(pystr::decode_utf8(content)?)?;
        Ok(match config.get("artifact_lifecycle") {
            None => false,
            Some(value) => matches!(value, toml::Value::String(text) if text == "enabled"),
        })
    }

    /// `validate_scope`: the UI/MCP scope token, or a daemon-owned
    /// same-project continuation when `internally_confirmed_project_id` is set.
    pub fn validate_scope(
        &self,
        encoded_token: Option<&str>,
        internally_confirmed_project_id: Option<&str>,
    ) -> Result<ScopeValidation> {
        if let Some(project_id) = internally_confirmed_project_id {
            if project_id != self.store.project_id {
                return Err(validation(
                    "internal lifecycle scope belongs to another project",
                ));
            }
            let (record, schema) = self.registry_record()?;
            return Ok(ScopeValidation {
                project_id: self.store.project_id.clone(),
                repository_path: record
                    .get("last_resolved_path")
                    .map(Value::py_str)
                    .unwrap_or_else(|| "None".to_string()),
                registry_schema_version: schema,
            });
        }
        let encoded = match encoded_token {
            Some(token) if !token.is_empty() => token,
            _ => {
                return Err(validation(
                    "artifact lifecycle dispatch requires a confirmed project scope token",
                ));
            }
        };
        let token = b64decode_validate(encoded)
            .and_then(|bytes| decode_json_bytes(&bytes))
            .ok_or_else(|| validation("confirmed project scope token is malformed"))?;
        let token = match token {
            Value::Dict(dict) if py_eq_optional(dict.get("version"), Some(&Value::Int(1))) => dict,
            _ => {
                return Err(validation(
                    "confirmed project scope token version is invalid",
                ));
            }
        };
        let (record, schema) = self.registry_record()?;
        let resolved = match token.get("repositoryPath") {
            Some(Value::Str(path)) => strict_resolve(path),
            _ => None,
        };
        if resolved.as_deref() != Some(self.store.repo_path.as_path()) {
            return Err(validation(
                "confirmed project scope token has stale repositoryPath",
            ));
        }
        let fingerprint = record.get("git_common_directory_fingerprint").cloned();
        let expected: [(&str, Value); 3] = [
            ("projectID", Value::Str(self.store.project_id.clone())),
            (
                "gitCommonDirectoryFingerprint",
                fingerprint.unwrap_or(Value::Null),
            ),
            ("registrySchemaVersion", Value::Int(schema)),
        ];
        for (key, value) in &expected {
            if !py_eq_optional(token.get(key), Some(value)) {
                return Err(validation(format!(
                    "confirmed project scope token has stale {key}"
                )));
            }
        }
        let token_updated = token.get("registryRecordUpdatedAt");
        let record_updated = registry_timestamp(record.get("updated_at"))?;
        let stale = match token_updated {
            Some(Value::Bool(flag)) => (f64::from(u8::from(*flag)) - record_updated).abs(),
            Some(Value::Int(number)) => (*number as f64 - record_updated).abs(),
            Some(Value::Float(number)) => (number - record_updated).abs(),
            Some(Value::BigInt(digits)) => digits
                .parse::<f64>()
                .map_or(f64::INFINITY, |number| (number - record_updated).abs()),
            _ => f64::INFINITY,
        };
        // `not (difference <= bound)`, so a NaN is stale as in Python.
        if !(stale <= 0.000_001) {
            return Err(validation("confirmed project scope token is stale"));
        }
        Ok(ScopeValidation {
            project_id: self.store.project_id.clone(),
            repository_path: self.store.repo_path.to_string_lossy().into_owned(),
            registry_schema_version: schema,
        })
    }

    /// `claim_and_materialize`: claim the ticket for the run, then write the
    /// read-only snapshot into the worker's worktree.
    pub fn claim_and_materialize(
        &self,
        ticket_id: &str,
        run_id: i64,
        provider: &str,
        workspace_path: &Path,
    ) -> Result<ArtifactWorkerSnapshot> {
        validate_provider(provider)?;
        let ticket_id = safe_id(ticket_id, "ticket ID")?;
        if run_id <= 0 {
            return Err(validation("run ID must be positive"));
        }
        let event_id = format!("lifecycle:run:{run_id}:claim");
        let prior = self.store.find_event(&event_id)?;
        let snapshot = self.store.snapshot()?;
        let ticket_path = format!(".orchestrator/{ticket_id}.md");
        let ticket_bytes = snapshot
            .file(&ticket_path)
            .ok_or_else(|| validation(format!("ticket {ticket_id} is not materialized")))?;
        let (fields, _) = split_ticket(ticket_bytes)?;
        let status = field(&fields, "status").unwrap_or("backlog");
        if prior.is_none() && status != "backlog" && status != "ready" {
            return Err(validation(format!(
                "ticket {ticket_id} is {}, not dispatchable through artifact lifecycle",
                pystr::repr(status)
            )));
        }
        if prior.is_some()
            && (status != "in_progress" || field(&fields, "run_id") != Some(&run_id.to_string()))
        {
            return Err(validation(format!(
                "idempotent claim for run {run_id} no longer matches canonical ticket state"
            )));
        }
        if truthy(field(&fields, "canceled").unwrap_or("false")) {
            return Err(validation(format!("ticket {ticket_id} is canceled")));
        }
        let artifact_id = match field(&fields, "artifact_id") {
            Some(value) if !value.is_empty() => value.to_string(),
            _ => {
                return Err(validation(format!(
                    "ticket {ticket_id} has no immutable artifact_id"
                )));
            }
        };
        let instant = self.instant();
        let resumed = if field(&fields, "run_state") == Some("verification_resumed") {
            field(&fields, "verification_resumed_run_id").map(str::to_string)
        } else {
            None
        };
        let claimed = rewrite_ticket(
            ticket_bytes,
            &updates(&[
                ("status", some("in_progress")),
                ("run_id", some(run_id.to_string())),
                ("run_state", some("claimed")),
                ("claimed_at", some(instant.clone())),
                ("activity_at", some(instant)),
                ("verification_resumed_run_id", resumed),
            ]),
        )?;
        if prior.is_none() {
            self.store.mutate(&self.mutation(
                &event_id,
                "system",
                Some(provider),
                &snapshot.commit_id,
                vec![ticket_write(ticket_id, &artifact_id, claimed)],
                format!("Claim {ticket_id} for run {run_id}"),
            ))?;
        }
        let claimed_snapshot = self.store.snapshot()?;
        let lease_id = format!("run:{run_id}:worker");
        let attachment_prefix = format!(".orchestrator/attachments/{ticket_id}/");
        let mut attachment_paths: Vec<String> = claimed_snapshot
            .files
            .iter()
            .map(|(path, _)| path.clone())
            .filter(|path| path.starts_with(&attachment_prefix))
            .collect();
        attachment_paths.sort();
        self.leases.acquire(&LeaseRequest {
            lease_id: lease_id.clone(),
            ticket_id: ticket_id.to_string(),
            artifact_id: artifact_id.clone(),
            artifact_head: claimed_snapshot.commit_id.clone(),
            run_id: run_id.to_string(),
            role: "worker".to_string(),
            provider: provider.to_string(),
            attachment_paths,
            now: Some(self.now()),
        })?;
        let materialized = self
            .materialize_snapshot(
                &claimed_snapshot,
                ticket_id,
                &artifact_id,
                run_id,
                provider,
                workspace_path,
            )
            .and_then(|(manifest_path, files)| {
                let manifest = fs::read(&manifest_path).map_err(|error| {
                    Error::new(ErrorKind::Io, os_error(&error, &manifest_path))
                })?;
                self.write_snapshot_proof(run_id, &claimed_snapshot.commit_id, &manifest)?;
                Ok((manifest_path, files))
            });
        let (manifest_path, files) = match materialized {
            Ok(value) => value,
            Err(error) => {
                self.release_if_active(&lease_id, "snapshot materialization failed")?;
                self.remove_snapshot_proof(run_id)?;
                return Err(error);
            }
        };
        Ok(ArtifactWorkerSnapshot {
            project_id: self.store.project_id.clone(),
            ticket_id: ticket_id.to_string(),
            artifact_id,
            artifact_head: claimed_snapshot.commit_id,
            run_id,
            provider: provider.to_string(),
            lease_id,
            manifest_path,
            files,
        })
    }

    /// `update_worker_sizing`: apply the four worker-sizing fields.
    pub fn update_worker_sizing(
        &self,
        ticket_id: &str,
        provider: &str,
        fields: &Dict,
    ) -> Result<LifecycleWriteResult> {
        validate_provider(provider)?;
        let mut sizing = Updates::new();
        let mut digest_source = Dict::new();
        for key in SIZING_KEYS {
            let value = bounded_value(fields.get(key), key, MAX_SUMMARY_BYTES)?;
            digest_source.insert(key, value.as_str());
            set(&mut sizing, key, Some(value));
        }
        let digest = hex_digest(canonical_json(&Value::Dict(digest_source)).as_bytes());
        let event_id = format!("lifecycle:sizing:{ticket_id}:{}", &digest[..24]);
        if let Some(prior) = self.prior_event(&event_id)? {
            return Ok(prior);
        }
        let snapshot = self.store.snapshot()?;
        let path = format!(".orchestrator/{ticket_id}.md");
        let content = snapshot
            .file(&path)
            .ok_or_else(|| validation(format!("canonical ticket {ticket_id} is missing")))?;
        let (ticket_fields, _) = split_ticket(content)?;
        let artifact_id = required_artifact_id(&ticket_fields, ticket_id)?;
        let write = self.store.mutate(&self.mutation(
            &event_id,
            "system",
            Some(provider),
            &snapshot.commit_id,
            vec![ticket_write(
                ticket_id,
                &artifact_id,
                rewrite_ticket(content, &sizing)?,
            )],
            format!("Apply worker sizing to {ticket_id}"),
        ))?;
        Ok(LifecycleWriteResult::new(
            &event_id,
            &write.commit_id,
            write.idempotent,
        ))
    }

    /// `submit_outcome`: record the worker's immutable structured outcome, or
    /// one superseding outcome whose commit descends from the recorded one.
    pub fn submit_outcome(
        &self,
        run_id: i64,
        ticket_id: &str,
        provider: &str,
        payload: &Dict,
        workspace_path: Option<&Path>,
    ) -> Result<StructuredWorkerOutcome> {
        let outcome = self.validate_outcome(run_id, ticket_id, provider, payload)?;
        let lease = self.lease_for_run(run_id, "worker")?;
        if lease.ticket_id != ticket_id || lease.provider != provider {
            return Err(validation(
                "worker outcome does not match its snapshot lease",
            ));
        }
        let encoded = canonical_line(&Value::Dict(outcome.to_json()));
        let path = self.outcome_path(run_id);
        let lock = outcome_lock(&path);
        let _guard = lock.lock().unwrap_or_else(|poison| poison.into_inner());
        if path.exists() {
            let existing = read_file(&path)?;
            if existing != encoded {
                // A lost response can leave a live worker unaware that its
                // first post was recorded; it may supersede it once.
                self.check_supersession(run_id, &outcome, workspace_path)?;
                let superseded = self.superseded_path(run_id);
                fs::write(&superseded, &existing)
                    .map_err(|error| Error::new(ErrorKind::Io, os_error(&error, &superseded)))?;
                replace_with(&path, &encoded)?;
            }
            return Ok(outcome);
        }
        create_dirs(path.parent().unwrap_or(Path::new(".")))?;
        replace_with(&path, &encoded)?;
        Ok(outcome)
    }

    fn check_supersession(
        &self,
        run_id: i64,
        outcome: &StructuredWorkerOutcome,
        workspace_path: Option<&Path>,
    ) -> Result<()> {
        let recorded = self.outcome(run_id)?;
        let recorded_commit = recorded
            .as_ref()
            .map_or("unknown".to_string(), |recorded| recorded.source_commit.clone());
        let problem = if self.superseded_path(run_id).exists() {
            "this run already superseded its outcome once"
        } else if let Some(workspace) = workspace_path {
            if outcome.source_commit != git_text(workspace, &["rev-parse", "HEAD"])? {
                "a superseding source_commit must be the worker's current HEAD"
            } else if outcome.source_commit == recorded_commit {
                "the recorded outcome already covers this source_commit"
            } else if !git_is_ancestor(workspace, &recorded_commit, &outcome.source_commit)? {
                "a superseding source_commit must be a new commit whose history contains \
                 the recorded source_commit (amended or rebased history is never accepted)"
            } else {
                return Ok(());
            }
        } else {
            "the run's worktree is unavailable to verify a superseding commit"
        };
        Err(validation(format!(
            "run {run_id} already submitted a different immutable outcome with \
             source_commit {recorded_commit}; {problem}. Read it back with \
             GET /v1/runs/{run_id}/outcome. To finish with the recorded outcome, restore \
             HEAD to {recorded_commit} (git reset --hard {recorded_commit}), leave no \
             uncommitted source changes, and exit without posting again."
        )))
    }

    /// `outcome`: the recorded outcome of a run, revalidated.
    pub fn outcome(&self, run_id: i64) -> Result<Option<StructuredWorkerOutcome>> {
        let path = self.outcome_path(run_id);
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(validation(format!(
                    "run {run_id} outcome store is corrupt: {}",
                    os_error(&error, &path)
                )));
            }
        };
        let payload = match read_text(&bytes).and_then(|text| json::parse(&text)) {
            Some(Value::Dict(payload)) => payload,
            Some(_) => {
                return Err(validation(format!(
                    "run {run_id} outcome store is corrupt: not a JSON object"
                )));
            }
            None => {
                return Err(validation(format!(
                    "run {run_id} outcome store is corrupt: invalid JSON"
                )));
            }
        };
        self.validate_outcome(
            run_id,
            &payload.string("ticket_id"),
            &payload.string("provider"),
            &payload,
        )
        .map(Some)
    }

    /// `validate_worker_completion`: the outcome status the daemon may act on
    /// (`completed`, `verification_blocked` or `verification_closeout`), or
    /// `None`, with the reason.
    pub fn validate_worker_completion(
        &self,
        workspace_path: &Path,
        ticket_id: &str,
        run_id: i64,
        provider: &str,
        start_head: Option<&str>,
    ) -> Result<(Option<String>, String)> {
        let reject = |reason: &str| Ok((None, reason.to_string()));
        let Some(outcome) = self.outcome(run_id)? else {
            return reject("worker did not submit a structured outcome");
        };
        if outcome.ticket_id != ticket_id || outcome.provider != provider {
            return reject("structured outcome ownership does not match the run");
        }
        match self.validate_materialized_snapshot(
            workspace_path,
            ticket_id,
            run_id,
            provider,
            start_head,
        ) {
            Err(error) if error.kind.is_validation() => return Ok((None, error.message)),
            Err(error) => return Err(error),
            Ok(()) => {}
        }
        let current_head = git_text(workspace_path, &["rev-parse", "HEAD"])?;
        if current_head.is_empty() || current_head != outcome.source_commit {
            return reject("structured outcome source_commit does not match worker HEAD");
        }
        if outcome.changed_paths.is_empty() {
            if start_head != Some(current_head.as_str()) {
                return reject("verification-only close-out must not commit source changes");
            }
            if !dirty_source_lines(workspace_path)?.is_empty() {
                return reject("worker left uncommitted source changes");
            }
            return Ok((
                Some("verification_closeout".to_string()),
                "verification-only close-out accepted".to_string(),
            ));
        }
        let Some(start) = start_head.filter(|start| *start != current_head) else {
            return reject("worker made no source commit");
        };
        let range = format!("{start}..{current_head}");
        let diff = git_text(workspace_path, &["diff", "--name-only", &range])?;
        let mut changed: Vec<String> = pystr::splitlines(&diff)
            .into_iter()
            .filter(|line| !line.is_empty())
            .map(str::to_string)
            .collect();
        changed.sort();
        let forbidden: Vec<&str> = changed
            .iter()
            .filter(|path| is_lifecycle_path(path))
            .map(String::as_str)
            .collect();
        if !forbidden.is_empty() {
            return Ok((
                None,
                format!(
                    "worker source branch contains lifecycle paths: {}",
                    forbidden.join(", ")
                ),
            ));
        }
        if changed != outcome.changed_paths {
            return reject("structured outcome changed_paths do not match committed source diff");
        }
        if !dirty_source_lines(workspace_path)?.is_empty() {
            return reject("worker left uncommitted source changes");
        }
        if outcome.status == WorkerOutcomeStatus::VerificationBlocked {
            return Ok((
                Some(outcome.status.value().to_string()),
                format!(
                    "verification blocked: {}; resume: {}",
                    py_optional(&outcome.verification_blocker),
                    py_optional(&outcome.verification_resume)
                ),
            ));
        }
        Ok((
            Some(outcome.status.value().to_string()),
            "structured worker outcome accepted".to_string(),
        ))
    }

    /// `begin_review`: move the run's snapshot lease from worker to reviewer.
    pub fn begin_review(&self, run_id: i64, provider: &str) -> Result<()> {
        if self.outcome(run_id)?.is_none() {
            return Err(validation(format!(
                "run {run_id} has no structured outcome to review"
            )));
        }
        let reviewer = format!("run:{run_id}:reviewer");
        if self
            .leases
            .active()?
            .iter()
            .any(|lease| lease.lease_id == reviewer)
        {
            return Ok(());
        }
        let worker = self.lease_for_run(run_id, "worker")?;
        self.leases.acquire(&LeaseRequest {
            lease_id: reviewer,
            ticket_id: worker.ticket_id.clone(),
            artifact_id: worker.artifact_id.clone(),
            artifact_head: worker.artifact_head.clone(),
            run_id: run_id.to_string(),
            role: "reviewer".to_string(),
            provider: provider.to_string(),
            attachment_paths: worker.attachment_paths.clone(),
            now: Some(self.now()),
        })?;
        self.release_if_active(&worker.lease_id, "worker outcome accepted for review")
    }

    /// `record_failure`: return the ticket to `backlog` (or `ready` for a
    /// retry) and release the run's leases.
    pub fn record_failure(
        &self,
        run_id: i64,
        ticket_id: &str,
        provider: &str,
        reason: &str,
        kind: FailureKind,
    ) -> Result<LifecycleWriteResult> {
        let reason = bounded_text(reason, "failure reason", MAX_SUMMARY_BYTES)?;
        let target_status = if kind.retry { "ready" } else { "backlog" };
        let (run_state, suffix) = if kind.canceled {
            ("canceled", "canceled")
        } else if kind.retry {
            ("retry_requested", "retry")
        } else {
            ("failed", "failed")
        };
        let result = self.update_ticket_event(TicketEvent {
            run_id,
            ticket_id,
            provider,
            event_id: &format!("lifecycle:run:{run_id}:{suffix}"),
            status: target_status,
            run_state,
            clear_run_id: true,
            log_summary: &format!("{}: {reason}", run_state.replace('_', " ")),
            clear_verification: false,
            extra_updates: &[],
        })?;
        self.release_run_leases(run_id, run_state)?;
        Ok(result)
    }

    /// `recover_spike_completion`: repair a publication interrupted after the
    /// canonical commit, before the ledger.
    pub fn recover_spike_completion(&self, run_id: i64) -> Result<Option<LifecycleWriteResult>> {
        let prior = self.prior_event(&format!("lifecycle:run:{run_id}:spike"))?;
        if prior.is_some() {
            self.store.recover()?;
            self.release_run_leases(run_id, "spike_completed")?;
        }
        Ok(prior)
    }

    /// `recover_spike_failure`: the run state a recorded spike failure or
    /// cancellation left, after repairing its leases.
    pub fn recover_spike_failure(&self, run_id: i64) -> Result<Option<String>> {
        for (suffix, state) in [("canceled", "Canceled"), ("failed", "Failed")] {
            if self
                .prior_event(&format!("lifecycle:run:{run_id}:{suffix}"))?
                .is_some()
            {
                self.store.recover()?;
                self.release_run_leases(run_id, suffix)?;
                return Ok(Some(state.to_string()));
            }
        }
        Ok(None)
    }

    /// `publish_spike_result`: publish a daemon-validated report without a
    /// source commit or reviewer lease.
    pub fn publish_spike_result(
        &self,
        run_id: i64,
        ticket_id: &str,
        provider: &str,
        workspace_path: &Path,
        report: &str,
    ) -> Result<LifecycleWriteResult> {
        validate_provider(provider)?;
        if let Some(prior) = self.recover_spike_completion(run_id)? {
            return Ok(prior);
        }
        if self.recover_spike_failure(run_id)?.is_some() {
            return Err(validation("spike run already failed or was canceled"));
        }
        bounded_text(report, "spike report", 128 * 1024)?;
        let head = git_text(workspace_path, &["rev-parse", "HEAD"])?;
        self.validate_materialized_snapshot(
            workspace_path,
            ticket_id,
            run_id,
            provider,
            Some(&head),
        )?;
        let lease = self.lease_for_run(run_id, "worker")?;
        let snapshot = self.store.snapshot()?;
        let path = format!(".orchestrator/{ticket_id}.md");
        let content = snapshot
            .file(&path)
            .ok_or_else(|| validation(format!("canonical ticket {ticket_id} is missing")))?;
        let (fields, _) = split_ticket(content)?;
        if field(&fields, "execution_mode") != Some("spike")
            || field(&fields, "status") != Some("in_progress")
            || field(&fields, "run_id") != Some(&run_id.to_string())
            || field(&fields, "artifact_id") != Some(lease.artifact_id.as_str())
            || lease.ticket_id != ticket_id
            || lease.provider != provider
            || truthy(field(&fields, "canceled").unwrap_or("false"))
        {
            return Err(validation(
                "canonical spike ticket changed; refusing overwrite",
            ));
        }
        let instant = self.instant();
        let updated = rewrite_ticket(
            content,
            &updates(&[
                ("status", some("done")),
                ("run_id", some(run_id.to_string())),
                ("run_state", some("spike_completed")),
                ("run_outcome_at", some(instant.clone())),
                ("activity_at", some(instant)),
            ]),
        )?;
        // Keep the report before the run log, including on an explicitly retried spike.
        let decoded = String::from_utf8(updated)
            .map_err(|_| Error::value("spike ticket is not UTF-8"))?;
        let mut text = SPIKE_REPORT.replace_all(&decoded, "").into_owned();
        let section = format!("## Spike report\n\n{}\n\n", pystr::strip(report));
        text = match text.find("## Run log") {
            Some(start) => format!("{}{section}{}", &text[..start], &text[start..]),
            None => format!("{}\n\n{section}", rstrip(&text)),
        };
        let updated = append_run_log(
            text.as_bytes(),
            run_id,
            "branchless spike completed; findings persisted by the daemon.",
        )?;
        let event_id = format!("lifecycle:run:{run_id}:spike");
        let write = self.store.mutate(&self.mutation(
            &event_id,
            "system",
            Some(provider),
            &snapshot.commit_id,
            vec![ticket_write(ticket_id, &lease.artifact_id, updated)],
            format!("Record spike findings for {ticket_id} run {run_id}"),
        ))?;
        self.release_run_leases(run_id, "spike_completed")?;
        Ok(LifecycleWriteResult::new(
            &event_id,
            &write.commit_id,
            write.idempotent,
        ))
    }

    /// `record_merge_conflict`.
    pub fn record_merge_conflict(
        &self,
        run_id: i64,
        ticket_id: &str,
        provider: &str,
        reason: &str,
    ) -> Result<LifecycleWriteResult> {
        let summary = format!(
            "merge conflict: {}",
            bounded_text(reason, "merge conflict", MAX_SUMMARY_BYTES)?
        );
        self.update_ticket_event(TicketEvent {
            run_id,
            ticket_id,
            provider,
            event_id: &format!("lifecycle:run:{run_id}:merge-conflict"),
            status: "in_progress",
            run_state: "merge_conflict",
            clear_run_id: false,
            log_summary: &summary,
            clear_verification: false,
            extra_updates: &[],
        })
    }

    /// `publish_merge_success`: publish `done` (or `verification_blocked`)
    /// after the reviewed source merge, promoting unblocked dependents.
    pub fn publish_merge_success(
        &self,
        run_id: i64,
        ticket_id: &str,
        provider: &str,
        merged_source_commit: &str,
    ) -> Result<LifecycleWriteResult> {
        let event_id = format!("lifecycle:run:{run_id}:merge");
        if let Some(prior) = self.prior_event(&event_id)? {
            self.release_run_leases(run_id, "merged")?;
            return Ok(prior);
        }
        let outcome = self
            .outcome(run_id)?
            .ok_or_else(|| validation(format!("run {run_id} has no structured outcome")))?;
        if outcome.ticket_id != ticket_id || outcome.provider != provider {
            return Err(validation(
                "merged outcome ownership does not match the run",
            ));
        }
        if !is_oid(merged_source_commit) {
            return Err(validation(
                "merged source commit is not a full Git object ID",
            ));
        }
        let source_head = git_text(&self.store.repo_path, &["rev-parse", "HEAD"])?;
        if source_head != merged_source_commit {
            return Err(validation(
                "canonical done publication requires the reviewed source merge at repository HEAD",
            ));
        }
        if !git_is_ancestor(
            &self.store.repo_path,
            &outcome.source_commit,
            merged_source_commit,
        )? {
            return Err(validation(
                "reviewed worker source commit is not reachable from the merged source HEAD",
            ));
        }
        let snapshot = self.store.snapshot()?;
        let path = format!(".orchestrator/{ticket_id}.md");
        let ticket_bytes = snapshot
            .file(&path)
            .ok_or_else(|| validation(format!("canonical ticket {ticket_id} is missing")))?;
        let (fields, _) = split_ticket(ticket_bytes)?;
        if field(&fields, "status") != Some("in_progress")
            || field(&fields, "run_id") != Some(&run_id.to_string())
        {
            return Err(validation(format!(
                "canonical ticket {ticket_id} no longer belongs to run {run_id}"
            )));
        }
        let artifact_id = required_artifact_id(&fields, ticket_id)?;
        let instant = self.instant();
        let status = if outcome.status == WorkerOutcomeStatus::VerificationBlocked {
            "verification_blocked"
        } else {
            "done"
        };
        let changes = updates(&[
            ("status", some(status)),
            ("run_id", some(run_id.to_string())),
            (
                "run_state",
                some(if status == "verification_blocked" {
                    "verification_blocked"
                } else {
                    "merged"
                }),
            ),
            ("merge_outcome_at", some(instant.clone())),
            ("activity_at", some(instant.clone())),
            ("verification_blocker", outcome.verification_blocker.clone()),
            ("verification_resume", outcome.verification_resume.clone()),
            ("verification_resumed_run_id", None),
        ]);
        let log = run_summary(&outcome, merged_source_commit)?;
        let finished = append_run_log(&rewrite_ticket(ticket_bytes, &changes)?, run_id, &log)?;
        let mut operations = vec![ticket_write(ticket_id, &artifact_id, finished)];
        let mut promoted = Vec::new();
        if status == "done" {
            promoted =
                self.promote_dependents_of_done(&snapshot, ticket_id, &instant, &mut operations)?;
        }
        let result = self.store.mutate(&self.mutation(
            &event_id,
            "reviewer",
            Some(provider),
            &snapshot.commit_id,
            operations,
            format!("Publish reviewed outcome for {ticket_id} run {run_id}"),
        ))?;
        self.release_run_leases(run_id, status)?;
        Ok(LifecycleWriteResult {
            event_id,
            commit_id: result.commit_id,
            promoted_ticket_ids: promoted,
            idempotent: result.idempotent,
        })
    }

    /// `publish_verification_closeout`: close a resumed verification-blocked
    /// ticket whose earlier source merge stands.
    pub fn publish_verification_closeout(
        &self,
        run_id: i64,
        ticket_id: &str,
        provider: &str,
    ) -> Result<LifecycleWriteResult> {
        let event_id = format!("lifecycle:run:{run_id}:verification-closeout");
        if let Some(prior) = self.prior_event(&event_id)? {
            self.release_run_leases(run_id, "done")?;
            return Ok(prior);
        }
        let outcome = self
            .outcome(run_id)?
            .ok_or_else(|| validation(format!("run {run_id} has no structured outcome")))?;
        if outcome.ticket_id != ticket_id || outcome.provider != provider {
            return Err(validation(
                "close-out outcome ownership does not match the run",
            ));
        }
        if !outcome.changed_paths.is_empty() {
            return Err(validation(
                "close-out outcome changed source and needs review",
            ));
        }
        let source_run_id = self
            .verification_closeout_source(run_id, ticket_id)?
            .ok_or_else(|| {
                validation(format!(
                    "run {run_id} is not a resumed close-out of a recorded source merge"
                ))
            })?;
        let snapshot = self.store.snapshot()?;
        let path = format!(".orchestrator/{ticket_id}.md");
        let ticket_bytes = snapshot
            .file(&path)
            .ok_or_else(|| Error::new(ErrorKind::Store, pystr::repr(&path)))?;
        let (fields, _) = split_ticket(ticket_bytes)?;
        let artifact_id = required_artifact_id(&fields, ticket_id)?;
        let instant = self.instant();
        let changes = updates(&[
            ("status", some("done")),
            ("run_id", some(run_id.to_string())),
            ("run_state", some("verification_closed")),
            ("run_outcome_at", some(instant.clone())),
            ("activity_at", some(instant.clone())),
            ("verification_resumed_run_id", None),
        ]);
        let log = bounded_text(
            &format!(
                "verification-only close-out after run {source_run_id}: {} Verification: {}",
                outcome.summary,
                outcome.verification.join("; ")
            ),
            "run summary",
            MAX_SUMMARY_BYTES,
        )?;
        let finished = append_run_log(&rewrite_ticket(ticket_bytes, &changes)?, run_id, &log)?;
        let mut operations = vec![ticket_write(ticket_id, &artifact_id, finished)];
        let promoted =
            self.promote_dependents_of_done(&snapshot, ticket_id, &instant, &mut operations)?;
        let result = self.store.mutate(&self.mutation(
            &event_id,
            "system",
            Some(provider),
            &snapshot.commit_id,
            operations,
            format!("Publish verification-only close-out for {ticket_id} run {run_id}"),
        ))?;
        self.release_run_leases(run_id, "done")?;
        Ok(LifecycleWriteResult {
            event_id,
            commit_id: result.commit_id,
            promoted_ticket_ids: promoted,
            idempotent: result.idempotent,
        })
    }

    fn retention_manager(&self) -> Result<ArtifactRetentionManager<'_>> {
        ArtifactRetentionManager::new(
            &self.store,
            RetentionOptions {
                lease_store: Some(self.leases.clone()),
                enabled: true,
                ..RetentionOptions::default()
            },
        )
    }

    /// `_promote_dependents_of_done`: append promotions for the backlog
    /// dependents that `ticket_id` becoming done unblocks.
    fn promote_dependents_of_done(
        &self,
        snapshot: &Snapshot,
        ticket_id: &str,
        instant: &str,
        operations: &mut Vec<Operation>,
    ) -> Result<Vec<String>> {
        let path = format!(".orchestrator/{ticket_id}.md");
        let files = sorted_files(snapshot);
        let mut statuses = status_map(&files)?;
        statuses.insert(ticket_id.to_string(), "done".to_string());
        let manager = self.retention_manager()?;
        let mut promoted = Vec::new();
        for (candidate_path, content) in &files {
            if !is_ticket_path(candidate_path) || *candidate_path == path {
                continue;
            }
            let (fields, _) = split_ticket(content)?;
            if field(&fields, "status") != Some("backlog") {
                continue;
            }
            if truthy(field(&fields, "canceled").unwrap_or("false"))
                || truthy(field(&fields, "draft").unwrap_or("false"))
            {
                continue;
            }
            let dependencies = parse_list(field(&fields, "depends_on").unwrap_or("[]"));
            if dependencies.is_empty()
                || !dependencies_allow_automatic_promotion(
                    &dependencies,
                    &statuses,
                    &manager,
                    None,
                )?
            {
                continue;
            }
            let candidate_id = path_stem(candidate_path);
            let candidate_artifact_id = match field(&fields, "artifact_id") {
                Some(value) if !value.is_empty() => value.to_string(),
                _ => {
                    return Err(validation(format!(
                        "dependent ticket {candidate_id} has no immutable artifact_id"
                    )));
                }
            };
            let advanced = rewrite_ticket(content, &promotion(instant))?;
            operations.push(ticket_write(&candidate_id, &candidate_artifact_id, advanced));
            statuses.insert(candidate_id.clone(), "ready".to_string());
            promoted.push(candidate_id);
        }
        Ok(promoted)
    }

    /// `promote_unblocked_dependents`: promote artifact-backed backlog tickets
    /// whose dependencies are done, through the canonical writer.
    pub fn promote_unblocked_dependents(&self) -> Result<Vec<String>> {
        let snapshot = self.store.snapshot()?;
        let (mut statuses, candidates) = self.dependent_candidates_at(&snapshot)?;
        let manager = self.retention_manager()?;
        let instant = self.instant();
        let mut operations = Vec::new();
        let mut promoted = Vec::new();
        for (candidate_path, content, fields, dependencies) in candidates.iter() {
            if !dependencies_allow_automatic_promotion(
                dependencies,
                &statuses,
                &manager,
                Some(&snapshot),
            )? {
                continue;
            }
            let ticket_id = path_stem(candidate_path);
            let artifact_id = match field(fields, "artifact_id") {
                Some(value) if !value.is_empty() => value.to_string(),
                _ => {
                    return Err(validation(format!(
                        "dependent ticket {ticket_id} has no immutable artifact_id"
                    )));
                }
            };
            let advanced = rewrite_ticket(content, &promotion(&instant))?;
            operations.push(ticket_write(&ticket_id, &artifact_id, advanced));
            statuses.insert(ticket_id.clone(), "ready".to_string());
            promoted.push(ticket_id);
        }
        if operations.is_empty() {
            return Ok(Vec::new());
        }
        self.store.mutate(&self.mutation(
            &format!("lifecycle:dependency-sweep:{}", snapshot.commit_id),
            "pm",
            None,
            &snapshot.commit_id,
            operations,
            "Promote artifact-backed dependency-ready tickets".to_string(),
        ))?;
        Ok(promoted)
    }

    /// `queue_for_dependencies`: move a backlog ticket to `ready` so it waits
    /// for its dependencies.
    pub fn queue_for_dependencies(&self, ticket_id: &str) -> Result<Option<LifecycleWriteResult>> {
        let snapshot = self.store.snapshot()?;
        let path = format!(".orchestrator/{ticket_id}.md");
        let content = snapshot
            .file(&path)
            .ok_or_else(|| validation(format!("canonical ticket {ticket_id} is missing")))?;
        let (fields, _) = split_ticket(content)?;
        if field(&fields, "status") != Some("backlog") {
            return Ok(None);
        }
        let artifact_id = match field(&fields, "artifact_id") {
            Some(value) if !value.is_empty() => value.to_string(),
            _ => {
                return Err(validation(format!(
                    "ticket {ticket_id} has no immutable artifact_id"
                )));
            }
        };
        let instant = self.instant();
        let event_id = format!(
            "lifecycle:dependency-queue:{ticket_id}:{}",
            snapshot.commit_id
        );
        let write = self.store.mutate(&self.mutation(
            &event_id,
            "pm",
            None,
            &snapshot.commit_id,
            vec![ticket_write(
                ticket_id,
                &artifact_id,
                rewrite_ticket(
                    content,
                    &updates(&[("status", some("ready")), ("activity_at", some(instant))]),
                )?,
            )],
            format!("Queue {ticket_id} until its dependencies are done"),
        ))?;
        Ok(Some(LifecycleWriteResult::new(
            &event_id,
            &write.commit_id,
            write.idempotent,
        )))
    }

    /// `resume_verification`: return a verification-blocked ticket to `ready`
    /// for a close-out run.
    pub fn resume_verification(
        &self,
        run_id: i64,
        ticket_id: &str,
        provider: &str,
        reason: &str,
    ) -> Result<LifecycleWriteResult> {
        let reason = bounded_text(reason, "verification resume reason", MAX_SUMMARY_BYTES)?;
        let event_id = format!("lifecycle:run:{run_id}:verification-resume");
        if let Some(prior) = self.prior_event(&event_id)? {
            return Ok(prior);
        }
        let snapshot = self.store.snapshot()?;
        let ticket_path = format!(".orchestrator/{ticket_id}.md");
        let content = snapshot
            .file(&ticket_path)
            .ok_or_else(|| validation(format!("canonical ticket {ticket_id} is missing")))?;
        let (fields, _) = split_ticket(content)?;
        if field(&fields, "status") != Some("verification_blocked") {
            return Err(validation(format!(
                "ticket {ticket_id} is not verification blocked"
            )));
        }
        if field(&fields, "run_id") != Some(&run_id.to_string()) {
            return Err(validation(format!(
                "ticket {ticket_id} does not belong to verification-blocked run {run_id}"
            )));
        }
        self.update_ticket_event(TicketEvent {
            run_id,
            ticket_id,
            provider,
            event_id: &event_id,
            status: "ready",
            run_state: "verification_resumed",
            clear_run_id: true,
            log_summary: &format!("verification resumed: {reason}"),
            clear_verification: true,
            extra_updates: &[("verification_resumed_run_id", some(run_id.to_string()))],
        })
    }

    /// `recover_leases`: release every active lease whose run `run_state`
    /// reports terminal or missing, except `preserve_run_ids`.
    pub fn recover_leases(
        &self,
        run_state: &dyn Fn(i64) -> Option<String>,
        preserve_run_ids: &[i64],
    ) -> Result<Vec<String>> {
        let mut released = Vec::new();
        for lease in self.leases.active()? {
            let Some(run_id) = pystr::int(&lease.run_id) else {
                continue;
            };
            if preserve_run_ids.contains(&run_id) {
                continue;
            }
            let state = run_state(run_id);
            let terminal = state
                .as_deref()
                .is_none_or(|state| TERMINAL_RUN_STATES.contains(&state));
            if terminal {
                self.leases.release(
                    &lease.lease_id,
                    &format!(
                        "daemon recovery observed terminal run state {}",
                        state.as_deref().filter(|state| !state.is_empty()).unwrap_or("missing")
                    ),
                    Some(self.now()),
                )?;
                released.push(lease.lease_id.clone());
                if !self
                    .leases
                    .active()?
                    .iter()
                    .any(|active| active.run_id == lease.run_id)
                {
                    self.remove_snapshot_proof(run_id)?;
                }
            }
        }
        Ok(released)
    }

    /// `cap_local_log`: keep the last `max_bytes` of a local log; the size
    /// it has afterwards, 0 when it cannot be read.
    pub fn cap_local_log(&self, path: &Path, max_bytes: u64) -> Result<u64> {
        let Ok(metadata) = fs::metadata(path) else {
            return Ok(0);
        };
        let size = metadata.len();
        if size <= max_bytes {
            return Ok(size);
        }
        let mut handle = fs::File::open(path)
            .map_err(|error| Error::new(ErrorKind::Io, os_error(&error, path)))?;
        handle.seek(SeekFrom::End(-(max_bytes as i64)))?;
        let mut tail = Vec::new();
        handle.read_to_end(&mut tail)?;
        replace_with(path, &tail)?;
        Ok(tail.len() as u64)
    }

    /// `cleanup_snapshot`: remove a worktree's snapshot, read-only bits and all.
    pub fn cleanup_snapshot(workspace_path: &Path) {
        let destination = workspace_path.join(".orchestrator");
        make_writable(&destination);
        let _ = fs::remove_dir_all(&destination);
    }

    fn validate_materialized_snapshot(
        &self,
        workspace_path: &Path,
        ticket_id: &str,
        run_id: i64,
        provider: &str,
        start_head: Option<&str>,
    ) -> Result<()> {
        let root = workspace_path.join(".orchestrator");
        let manifest_path = root.join(".artifact-snapshot.json");
        let manifest = read_json_file(&manifest_path).map_err(|reason| {
            validation(format!(
                "immutable worker snapshot manifest is unavailable: {reason}"
            ))
        })?;
        let manifest = match manifest {
            Value::Dict(manifest)
                if py_eq_optional(
                    manifest.get("schema_version"),
                    Some(&Value::Int(SNAPSHOT_SCHEMA_VERSION)),
                ) =>
            {
                manifest
            }
            _ => {
                return Err(validation(
                    "immutable worker snapshot manifest is invalid",
                ));
            }
        };
        let identity = [
            ("project_id", Value::from(self.store.project_id.as_str())),
            ("ticket_id", Value::from(ticket_id)),
            ("run_id", Value::Int(run_id)),
            ("provider", Value::from(provider)),
        ];
        if identity
            .iter()
            .any(|(key, value)| !py_eq_optional(manifest.get(key), Some(value)))
        {
            return Err(validation("immutable worker snapshot identity changed"));
        }
        match start_head {
            Some(head)
                if !head.is_empty()
                    && py_eq_optional(
                        manifest.get("source_start_head"),
                        Some(&Value::from(head)),
                    ) => {}
            _ => {
                return Err(validation(
                    "immutable worker snapshot source base changed",
                ));
            }
        }
        let lease = self.lease_for_run(run_id, "worker")?;
        let lease_head = Value::from(lease.artifact_head.as_str());
        if !py_eq_optional(manifest.get("artifact_head"), Some(&lease_head)) {
            return Err(validation(
                "immutable worker snapshot artifact head changed",
            ));
        }
        let proof_path = self.snapshot_proof_path(run_id);
        let proof = read_json_file(&proof_path).map_err(|reason| {
            validation(format!(
                "immutable worker snapshot proof is unavailable: {reason}"
            ))
        })?;
        let manifest_digest = hex_digest(&read_file(&manifest_path)?);
        let proof_matches = proof.as_dict().is_some_and(|proof| {
            py_eq_optional(proof.get("run_id"), Some(&Value::Int(run_id)))
                && py_eq_optional(proof.get("artifact_head"), Some(&lease_head))
                && py_eq_optional(
                    proof.get("manifest_sha256"),
                    Some(&Value::Str(manifest_digest.clone())),
                )
        });
        if !proof_matches {
            return Err(validation("immutable worker snapshot manifest changed"));
        }
        let declared = match manifest.get("files") {
            Some(Value::Dict(files)) if !files.is_empty() => files,
            _ => {
                return Err(validation(
                    "immutable worker snapshot has no file manifest",
                ));
            }
        };
        let mut actual = BTreeSet::new();
        collect_snapshot_files(&root, &root, &mut actual)?;
        let declared_paths: BTreeSet<String> =
            declared.iter().map(|(path, _)| path.to_string()).collect();
        if actual != declared_paths {
            return Err(validation(
                "immutable worker snapshot file set changed",
            ));
        }
        for (relative, metadata) in declared.iter() {
            let Some(metadata) = metadata.as_dict() else {
                return Err(validation(
                    "immutable worker snapshot file metadata is invalid",
                ));
            };
            let content = fs::read(workspace_path.join(relative)).map_err(|_| {
                validation(format!(
                    "immutable worker snapshot file is unavailable: {relative}"
                ))
            })?;
            if !py_eq_optional(metadata.get("bytes"), Some(&Value::Int(content.len() as i64)))
                || !py_eq_optional(
                    metadata.get("sha256"),
                    Some(&Value::Str(hex_digest(&content))),
                )
            {
                return Err(validation(format!(
                    "immutable worker snapshot file changed: {relative}"
                )));
            }
        }
        Ok(())
    }

    /// `_is_stale_snapshot`: whether the snapshot belongs to an earlier,
    /// no-longer-leased run of this ticket.
    fn is_stale_snapshot(&self, destination: &Path, ticket_id: &str, run_id: i64) -> Result<bool> {
        if is_symlink(destination) || !destination.is_dir() {
            return Ok(false);
        }
        let Ok(Value::Dict(manifest)) = read_json_file(&destination.join(".artifact-snapshot.json"))
        else {
            return Ok(false);
        };
        let prior_run = match manifest.get("run_id") {
            Some(Value::Int(number)) => (*number, number.to_string()),
            Some(Value::Bool(flag)) => (
                i64::from(*flag),
                if *flag { "True" } else { "False" }.to_string(),
            ),
            _ => return Ok(false),
        };
        if !py_eq_optional(
            manifest.get("project_id"),
            Some(&Value::from(self.store.project_id.as_str())),
        ) || !py_eq_optional(manifest.get("ticket_id"), Some(&Value::from(ticket_id)))
            || prior_run.0 == run_id
        {
            return Ok(false);
        }
        Ok(!self
            .leases
            .active()?
            .iter()
            .any(|lease| lease.run_id == prior_run.1))
    }

    fn materialize_snapshot(
        &self,
        snapshot: &Snapshot,
        ticket_id: &str,
        artifact_id: &str,
        run_id: i64,
        provider: &str,
        workspace_path: &Path,
    ) -> Result<(PathBuf, Vec<String>)> {
        let tracked = git_text(
            workspace_path,
            &["ls-files", "--", ".orchestrator", ".relay"],
        )?;
        if !tracked.is_empty() {
            return Err(validation(
                "artifact lifecycle requires reviewed source cleanup; source branch still tracks lifecycle paths",
            ));
        }
        let destination = workspace_path.join(".orchestrator");
        if destination.exists() || is_symlink(&destination) {
            if !self.is_stale_snapshot(&destination, ticket_id, run_id)? {
                return Err(validation("worker snapshot destination already exists"));
            }
            // A reused worktree still holds an ended run's snapshot; replace it.
            Self::cleanup_snapshot(workspace_path);
        }
        let files = sorted_files(snapshot);
        let ticket_path = format!(".orchestrator/{ticket_id}.md");
        let ticket = files
            .get(ticket_path.as_str())
            .ok_or_else(|| Error::new(ErrorKind::Store, pystr::repr(&ticket_path)))?;
        let mut selected: BTreeMap<String, Vec<u8>> = BTreeMap::new();
        selected.insert(ticket_path.clone(), ticket.to_vec());
        let attachment_prefix = format!(".orchestrator/attachments/{ticket_id}/");
        for (path, content) in &files {
            if path.starts_with(&attachment_prefix) {
                selected.insert(path.to_string(), content.to_vec());
            }
        }
        let (fields, _) = split_ticket(ticket)?;
        let catalog = catalog(&files)?;
        let mut summaries = Vec::new();
        for dependency_id in parse_list(field(&fields, "depends_on").unwrap_or("[]")) {
            let dependency_path = format!(".orchestrator/{dependency_id}.md");
            if let Some(content) = files.get(dependency_path.as_str()) {
                let (dependency, _) = split_ticket(content)?;
                let mut summary = Dict::new();
                summary.insert("ticket_id", dependency_id.as_str());
                summary.insert("artifact_id", optional_str(field(&dependency, "artifact_id")));
                summary.insert(
                    "title",
                    field(&dependency, "title").unwrap_or(dependency_id.as_str()),
                );
                summary.insert("status", field(&dependency, "status").unwrap_or("unknown"));
                summary.insert("activity_at", optional_str(field(&dependency, "activity_at")));
                summary.insert("archived", false);
                summaries.push((dependency_id, summary));
                continue;
            }
            let needle = Value::Str(dependency_id.clone());
            let archived = catalog
                .iter()
                .map(|(_, entry)| entry)
                .find(|entry| py_eq_optional(entry.get("ticket_id"), Some(&needle)))
                .ok_or_else(|| {
                    validation(format!(
                        "required dependency {dependency_id} is absent from artifact snapshot and catalog"
                    ))
                })?;
            let mut summary = Dict::new();
            summary.insert("ticket_id", dependency_id.as_str());
            summary.insert(
                "artifact_id",
                archived.get("artifact_id").cloned().unwrap_or(Value::Null),
            );
            summary.insert(
                "title",
                archived
                    .get("title")
                    .cloned()
                    .unwrap_or_else(|| Value::Str(dependency_id.clone())),
            );
            summary.insert(
                "status",
                archived
                    .get("status")
                    .cloned()
                    .unwrap_or_else(|| Value::from("unknown")),
            );
            summary.insert(
                "activity_at",
                archived.get("activity_at").cloned().unwrap_or(Value::Null),
            );
            summary.insert("archived", true);
            summaries.push((dependency_id, summary));
        }
        for (dependency_id, summary) in summaries {
            selected.insert(
                format!(".orchestrator/dependencies/{dependency_id}.json"),
                canonical_line(&Value::Dict(summary)),
            );
        }
        let mut file_manifest = Dict::new();
        for (path, content) in &selected {
            let mut metadata = Dict::new();
            metadata.insert("sha256", hex_digest(content));
            metadata.insert("bytes", content.len() as i64);
            file_manifest.insert(path, metadata);
        }
        let mut manifest = Dict::new();
        manifest.insert("schema_version", SNAPSHOT_SCHEMA_VERSION);
        manifest.insert("project_id", self.store.project_id.as_str());
        manifest.insert("ticket_id", ticket_id);
        manifest.insert("artifact_id", artifact_id);
        manifest.insert("artifact_head", snapshot.commit_id.as_str());
        manifest.insert("run_id", run_id);
        manifest.insert("provider", provider);
        manifest.insert(
            "source_start_head",
            git_text(workspace_path, &["rev-parse", "HEAD"])?,
        );
        manifest.insert("files", file_manifest);
        selected.insert(
            SNAPSHOT_MANIFEST.to_string(),
            canonical_line(&Value::Dict(manifest)),
        );
        if let Err(error) = write_read_only_tree(workspace_path, &destination, &selected) {
            make_writable(&destination);
            let _ = fs::remove_dir_all(&destination);
            return Err(validation(format!(
                "could not materialize immutable worker snapshot: {error}"
            )));
        }
        Ok((
            workspace_path.join(SNAPSHOT_MANIFEST),
            selected.into_keys().collect(),
        ))
    }

    fn validate_outcome(
        &self,
        run_id: i64,
        ticket_id: &str,
        provider: &str,
        payload: &Dict,
    ) -> Result<StructuredWorkerOutcome> {
        if run_id <= 0 {
            return Err(validation("outcome run ID must be positive"));
        }
        let ticket_id = safe_id(ticket_id, "ticket ID")?;
        validate_provider(provider)?;
        let whole = Value::Dict(payload.clone());
        let forbidden = store::find_forbidden_keys(&whole);
        if !forbidden.is_empty() {
            return Err(validation(format!(
                "structured outcome contains prohibited Git content: {}",
                forbidden.into_iter().collect::<Vec<_>>().join(", ")
            )));
        }
        let mut extra: Vec<&str> = payload
            .iter()
            .map(|(key, _)| key)
            .filter(|key| !OUTCOME_KEYS.contains(key))
            .collect();
        extra.sort();
        extra.dedup();
        if !extra.is_empty() {
            return Err(validation(format!(
                "structured outcome contains unknown fields: {}",
                extra.join(", ")
            )));
        }
        let defaulted = |key: &str, default: Value| -> bool {
            py_eq(payload.get(key).unwrap_or(&default), &default)
        };
        if !defaulted("schema_version", Value::Int(OUTCOME_SCHEMA_VERSION)) {
            return Err(validation("structured outcome schema version is invalid"));
        }
        if !defaulted("run_id", Value::Int(run_id)) || !defaulted("ticket_id", Value::from(ticket_id))
        {
            return Err(validation(
                "structured outcome identity does not match its endpoint",
            ));
        }
        if !defaulted("project_id", Value::from(self.store.project_id.as_str())) {
            return Err(validation("structured outcome belongs to another project"));
        }
        if !defaulted("provider", Value::from(provider)) {
            return Err(validation(
                "structured outcome provider does not match the run",
            ));
        }
        let status = WorkerOutcomeStatus::from_value(&payload.string("status"))
            .ok_or_else(|| validation("structured outcome status is invalid"))?;
        let summary = bounded_value(payload.get("summary"), "outcome summary", MAX_SUMMARY_BYTES)?;
        let Some(Value::List(raw_verification)) = payload.get("verification") else {
            return Err(validation(
                "structured outcome verification must be a list",
            ));
        };
        let verification = raw_verification
            .iter()
            .map(|item| bounded_value(Some(item), "verification item", MAX_VERIFICATION_BYTES))
            .collect::<Result<Vec<_>>>()?;
        if verification.iter().map(String::len).sum::<usize>() > MAX_VERIFICATION_BYTES {
            return Err(validation(
                "structured outcome verification exceeds its total bound",
            ));
        }
        let blocker = optional_bounded(payload.get("verification_blocker"), MAX_SUMMARY_BYTES)?;
        let resume = optional_bounded(payload.get("verification_resume"), MAX_SUMMARY_BYTES)?;
        let raw_paths = payload.get("changed_paths");
        let empty_list = matches!(raw_paths, Some(Value::List(items)) if items.is_empty());
        let verification_only = empty_list
            && status == WorkerOutcomeStatus::Completed
            && blocker.as_deref().is_none_or(str::is_empty)
            && resume.as_deref().is_none_or(str::is_empty)
            && !verification.is_empty()
            && self.allows_verification_only(run_id, ticket_id)?;
        let raw_paths = match raw_paths {
            Some(Value::List(items))
                if (!items.is_empty() || verification_only) && items.len() <= MAX_CHANGED_PATHS =>
            {
                items
            }
            _ => {
                return Err(validation(
                    "structured outcome changed_paths is empty or exceeds its bound",
                ));
            }
        };
        let mut changed_paths = raw_paths
            .iter()
            .map(validate_source_path)
            .collect::<Result<Vec<_>>>()?;
        changed_paths.sort();
        changed_paths.dedup();
        if changed_paths.len() != raw_paths.len() {
            return Err(validation(
                "structured outcome changed_paths contains duplicates",
            ));
        }
        let source_commit = payload.string("source_commit");
        if !is_oid(&source_commit) {
            return Err(validation("structured outcome source_commit is invalid"));
        }
        if status == WorkerOutcomeStatus::VerificationBlocked
            && (blocker.is_none() || resume.is_none())
        {
            return Err(validation(
                "verification-blocked outcome requires blocker and explicit resume condition",
            ));
        }
        if status == WorkerOutcomeStatus::Completed && (blocker.is_some() || resume.is_some()) {
            return Err(validation(
                "completed outcome cannot carry verification blocker metadata",
            ));
        }
        store::reject_secrets(canonical_json(&whole).as_bytes(), "structured worker outcome")?;
        Ok(StructuredWorkerOutcome {
            schema_version: OUTCOME_SCHEMA_VERSION,
            project_id: self.store.project_id.clone(),
            ticket_id: ticket_id.to_string(),
            run_id,
            provider: provider.to_string(),
            status,
            summary,
            changed_paths,
            verification,
            source_commit,
            verification_blocker: blocker,
            verification_resume: resume,
        })
    }

    /// `_verification_closeout_source`: the blocked run whose recorded merge
    /// this resumed run may close out.
    fn verification_closeout_source(&self, run_id: i64, ticket_id: &str) -> Result<Option<i64>> {
        let snapshot = self.store.snapshot()?;
        let Some(content) = snapshot.file(&format!(".orchestrator/{ticket_id}.md")) else {
            return Ok(None);
        };
        let (fields, _) = split_ticket(content)?;
        if field(&fields, "status") != Some("in_progress")
            || field(&fields, "run_id") != Some(&run_id.to_string())
        {
            return Ok(None);
        }
        let source = field(&fields, "verification_resumed_run_id").unwrap_or("");
        let Some(number) = py_isdigit_int(source) else {
            return Ok(None);
        };
        if number <= 0 || number == run_id {
            return Ok(None);
        }
        for suffix in ["merge", "verification-resume"] {
            if self
                .prior_event(&format!("lifecycle:run:{source}:{suffix}"))?
                .is_none()
            {
                return Ok(None);
            }
        }
        Ok(Some(number))
    }

    fn allows_verification_only(&self, run_id: i64, ticket_id: &str) -> Result<bool> {
        if self
            .prior_event(&format!("lifecycle:run:{run_id}:verification-closeout"))?
            .is_some()
        {
            return Ok(true);
        }
        Ok(self
            .verification_closeout_source(run_id, ticket_id)?
            .is_some())
    }

    fn update_ticket_event(&self, event: TicketEvent<'_>) -> Result<LifecycleWriteResult> {
        validate_provider(event.provider)?;
        if let Some(prior) = self.prior_event(event.event_id)? {
            return Ok(prior);
        }
        let ticket_id = event.ticket_id;
        let run_id = event.run_id;
        let snapshot = self.store.snapshot()?;
        let path = format!(".orchestrator/{ticket_id}.md");
        let content = snapshot
            .file(&path)
            .ok_or_else(|| validation(format!("canonical ticket {ticket_id} is missing")))?;
        let (fields, _) = split_ticket(content)?;
        let current_run_id = pystr::strip(field(&fields, "run_id").unwrap_or("")).to_lowercase();
        if current_run_id != run_id.to_string() {
            let unclaimed_failure = event.run_state == "failed"
                && (current_run_id.is_empty() || current_run_id == "null")
                && matches!(field(&fields, "status"), Some("backlog" | "ready"));
            if !unclaimed_failure {
                return Err(validation(format!(
                    "canonical ticket {ticket_id} no longer belongs to run {run_id}"
                )));
            }
        }
        let artifact_id = required_artifact_id(&fields, ticket_id)?;
        let instant = self.instant();
        let mut changes = updates(&[
            ("status", some(event.status)),
            (
                "run_id",
                some(if event.clear_run_id {
                    "null".to_string()
                } else {
                    run_id.to_string()
                }),
            ),
            ("run_state", some(event.run_state)),
            ("run_outcome_at", some(instant.clone())),
            ("activity_at", some(instant)),
        ]);
        if event.clear_verification {
            set(&mut changes, "verification_blocker", None);
            set(&mut changes, "verification_resume", None);
        }
        for (key, value) in event.extra_updates {
            set(&mut changes, key, value.clone());
        }
        let updated = append_run_log(
            &rewrite_ticket(content, &changes)?,
            run_id,
            &bounded_text(event.log_summary, "run summary", MAX_SUMMARY_BYTES)?,
        )?;
        let write = self.store.mutate(&self.mutation(
            event.event_id,
            "system",
            Some(event.provider),
            &snapshot.commit_id,
            vec![ticket_write(ticket_id, &artifact_id, updated)],
            format!("Record {} for {ticket_id} run {run_id}", event.run_state),
        ))?;
        Ok(LifecycleWriteResult::new(
            event.event_id,
            &write.commit_id,
            write.idempotent,
        ))
    }

    fn prior_event(&self, event_id: &str) -> Result<Option<LifecycleWriteResult>> {
        Ok(self
            .store
            .find_event(event_id)?
            .map(|(commit_id, _)| LifecycleWriteResult::new(event_id, &commit_id, true)))
    }

    fn dependent_candidates_at(
        &self,
        snapshot: &Snapshot,
    ) -> Result<(HashMap<String, String>, Arc<Vec<Candidate>>)> {
        // A commit's files never change, and the app's watchdog sweeps every
        // few seconds, so each head's tickets are parsed once (RR-440).
        let mut cache = self
            .dependent_candidates
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if let Some(cached) = cache.as_ref()
            && cached.head == snapshot.commit_id
        {
            return Ok((cached.statuses.clone(), Arc::clone(&cached.candidates)));
        }
        let files = sorted_files(snapshot);
        let statuses = status_map(&files)?;
        let mut candidates = Vec::new();
        for (candidate_path, content) in &files {
            if !is_ticket_path(candidate_path) {
                continue;
            }
            let (fields, _) = split_ticket(content)?;
            if field(&fields, "status") != Some("backlog") {
                continue;
            }
            if truthy(field(&fields, "canceled").unwrap_or("false"))
                || truthy(field(&fields, "draft").unwrap_or("false"))
            {
                continue;
            }
            let dependencies = parse_list(field(&fields, "depends_on").unwrap_or("[]"));
            if !dependencies.is_empty() {
                candidates.push((
                    candidate_path.to_string(),
                    content.to_vec(),
                    fields,
                    dependencies,
                ));
            }
        }
        let candidates = Arc::new(candidates);
        *cache = Some(CandidateCache {
            head: snapshot.commit_id.clone(),
            statuses: statuses.clone(),
            candidates: Arc::clone(&candidates),
        });
        Ok((statuses, candidates))
    }

    fn registry_record(&self) -> Result<(Dict, i64)> {
        let document = read_json_file(&self.registry_path).map_err(|reason| {
            validation(format!(
                "confirmed project registry is unavailable: {reason}"
            ))
        })?;
        let empty = Dict::new();
        let document = document.as_dict().unwrap_or(&empty);
        if !py_eq_optional(document.get("schema_version"), Some(&Value::Int(2))) {
            return Err(validation("confirmed project registry schema is invalid"));
        }
        let project = Value::from(self.store.project_id.as_str());
        let matches: Vec<&Dict> = document
            .get("projects")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .filter_map(Value::as_dict)
            .filter(|item| py_eq_optional(item.get("project_id"), Some(&project)))
            .collect();
        if matches.len() != 1 {
            return Err(validation(
                "project is missing or duplicated in registry-v2",
            ));
        }
        let record = matches[0].clone();
        if !record
            .get("availability")
            .is_some_and(|value| value.is_str("available"))
        {
            return Err(validation(format!(
                "confirmed project is unavailable: {}",
                py_repr(record.get("availability"))
            )));
        }
        let path = paths::resolve(&record.string("last_resolved_path"));
        if Path::new(&path) != self.store.repo_path {
            return Err(validation(
                "registered project path does not match artifact repository",
            ));
        }
        Ok((record, 2))
    }

    fn lease_for_run(&self, run_id: i64, role: &str) -> Result<SnapshotLease> {
        let lease_id = format!("run:{run_id}:{role}");
        let mut matches: Vec<SnapshotLease> = self
            .leases
            .active()?
            .into_iter()
            .filter(|lease| lease.lease_id == lease_id)
            .collect();
        if matches.len() != 1 {
            return Err(validation(format!(
                "run {run_id} has no active {role} snapshot lease"
            )));
        }
        Ok(matches.remove(0))
    }

    fn release_if_active(&self, lease_id: &str, reason: &str) -> Result<()> {
        if self
            .leases
            .active()?
            .iter()
            .any(|lease| lease.lease_id == lease_id)
        {
            self.leases.release(lease_id, reason, Some(self.now()))?;
        }
        Ok(())
    }

    fn release_run_leases(&self, run_id: i64, reason: &str) -> Result<()> {
        for role in ["worker", "reviewer"] {
            self.release_if_active(&format!("run:{run_id}:{role}"), reason)?;
        }
        self.remove_snapshot_proof(run_id)
    }

    /// `<project state>/lifecycle/outcomes/run-<id>.json`.
    pub fn outcome_path(&self, run_id: i64) -> PathBuf {
        self.outcome_root.join(format!("run-{run_id}.json"))
    }

    /// `<project state>/lifecycle/outcomes/run-<id>.superseded.json`.
    pub fn superseded_path(&self, run_id: i64) -> PathBuf {
        self.outcome_root.join(format!("run-{run_id}.superseded.json"))
    }

    /// `<project state>/lifecycle/snapshot-proofs/run-<id>.json`.
    pub fn snapshot_proof_path(&self, run_id: i64) -> PathBuf {
        self.snapshot_proof_root.join(format!("run-{run_id}.json"))
    }

    fn write_snapshot_proof(&self, run_id: i64, artifact_head: &str, manifest: &[u8]) -> Result<()> {
        let mut proof = Dict::new();
        proof.insert("run_id", run_id);
        proof.insert("artifact_head", artifact_head);
        proof.insert("manifest_sha256", hex_digest(manifest));
        let payload = canonical_line(&Value::Dict(proof));
        let path = self.snapshot_proof_path(run_id);
        let lock = outcome_lock(&path);
        let _guard = lock.lock().unwrap_or_else(|poison| poison.into_inner());
        if path.exists() {
            if read_file(&path)? != payload {
                return Err(validation(format!(
                    "run {run_id} already has a different immutable snapshot proof"
                )));
            }
            return Ok(());
        }
        create_dirs(path.parent().unwrap_or(Path::new(".")))?;
        replace_with(&path, &payload)
    }

    fn remove_snapshot_proof(&self, run_id: i64) -> Result<()> {
        match fs::remove_file(self.snapshot_proof_path(run_id)) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        }
    }

    fn mutation(
        &self,
        event_id: &str,
        actor_type: &str,
        provider: Option<&str>,
        expected_base: &str,
        operations: Vec<Operation>,
        summary: String,
    ) -> Mutation {
        let mut mutation = Mutation::new(event_id, actor_type, &self.device_id, operations);
        mutation.provider = provider.map(str::to_string);
        mutation.expected_base = Some(expected_base.to_string());
        mutation.summary = summary;
        mutation
    }
}

/// `_update_ticket_event`'s keyword arguments.
struct TicketEvent<'a> {
    run_id: i64,
    ticket_id: &'a str,
    provider: &'a str,
    event_id: &'a str,
    status: &'a str,
    run_state: &'a str,
    clear_run_id: bool,
    log_summary: &'a str,
    clear_verification: bool,
    extra_updates: &'a [(&'a str, Option<String>)],
}

fn dependencies_allow_automatic_promotion(
    dependencies: &[String],
    statuses: &HashMap<String, String>,
    manager: &ArtifactRetentionManager<'_>,
    snapshot: Option<&Snapshot>,
) -> Result<bool> {
    for dependency_id in dependencies {
        if statuses.get(dependency_id).map(String::as_str) != Some("done")
            && !manager.dependency_satisfied(dependency_id, snapshot)?
        {
            return Ok(false);
        }
        if manager.dependency_execution_mode(dependency_id, snapshot)? == Some("spike".to_string()) {
            return Ok(false);
        }
    }
    Ok(true)
}

fn promotion(instant: &str) -> Updates {
    updates(&[
        ("status", some("ready")),
        ("run_state", some("dependency_ready")),
        ("dependency_updated_at", some(instant)),
        ("activity_at", some(instant)),
    ])
}

fn ticket_write(ticket_id: &str, artifact_id: &str, markdown: Vec<u8>) -> Operation {
    Operation::TicketWrite {
        ticket_id: ticket_id.to_string(),
        artifact_id: artifact_id.to_string(),
        markdown,
    }
}

fn required_artifact_id(fields: &TicketFields, ticket_id: &str) -> Result<String> {
    match field(fields, "artifact_id") {
        Some(value) if !value.is_empty() => Ok(value.to_string()),
        _ => Err(validation(format!(
            "ticket {ticket_id} has no immutable artifact_id"
        ))),
    }
}

fn field<'f>(fields: &'f TicketFields, key: &str) -> Option<&'f str> {
    fields.get(key).map(String::as_str)
}

fn sorted_files(snapshot: &Snapshot) -> BTreeMap<&str, &[u8]> {
    snapshot
        .files
        .iter()
        .map(|(path, content)| (path.as_str(), content.as_slice()))
        .collect()
}

/// `_status_map`: every ticket's status, then the archive catalog's for
/// tickets that are not materialized.
fn status_map(files: &BTreeMap<&str, &[u8]>) -> Result<HashMap<String, String>> {
    let mut statuses = HashMap::new();
    for (path, content) in files {
        if is_ticket_path(path) {
            let (fields, _) = split_ticket(content)?;
            statuses.insert(
                path_stem(path),
                field(&fields, "status").unwrap_or("backlog").to_string(),
            );
        }
    }
    for (_, entry) in catalog(files)? {
        let ticket_id = entry
            .get("ticket_id")
            .map_or("None".to_string(), Value::py_str);
        let status = entry.get("status").map(Value::py_str).unwrap_or_default();
        statuses.entry(ticket_id).or_insert(status);
    }
    Ok(statuses)
}

/// `_catalog`: the archive index's entries by artifact ID, in first-seen
/// order, a repeated artifact ID keeping its last entry.
fn catalog(files: &BTreeMap<&str, &[u8]>) -> Result<Vec<(String, Dict)>> {
    let mut result: Vec<(String, Dict)> = Vec::new();
    let Some(content) = files.get(ARCHIVE_INDEX) else {
        return Ok(result);
    };
    let text = pystr::decode_utf8(content)?;
    for line in pystr::splitlines(text) {
        if pystr::strip(line).is_empty() {
            continue;
        }
        let entry = json::parse(line)
            .ok_or_else(|| Error::value("archive index line is not valid JSON"))?;
        if let Value::Dict(entry) = entry
            && let Some(Value::Str(artifact_id)) = entry.get("artifact_id")
        {
            let artifact_id = artifact_id.clone();
            match result.iter_mut().find(|(key, _)| *key == artifact_id) {
                Some(existing) => existing.1 = entry,
                None => result.push((artifact_id, entry)),
            }
        }
    }
    Ok(result)
}

// -- ticket text ----------------------------------------------------------

/// `_split_ticket`: the front-matter fields and the body lines.
pub fn split_ticket(content: &[u8]) -> Result<(TicketFields, Vec<String>)> {
    let text = std::str::from_utf8(content).map_err(|_| validation("ticket is not UTF-8"))?;
    let lines = pystr::splitlines(text);
    if lines.first().is_none_or(|line| pystr::strip(line) != "---") {
        return Err(validation("ticket has no YAML front matter"));
    }
    let mut fields = TicketFields::new();
    let mut closing = None;
    for (index, line) in lines.iter().enumerate().skip(1) {
        if pystr::strip(line) == "---" {
            closing = Some(index);
            break;
        }
        let (key, separated, value) = pystr::partition(line, ":");
        if separated {
            fields.insert(
                pystr::strip(key).to_string(),
                pystr::strip_quotes(pystr::strip(value)).to_string(),
            );
        }
    }
    let closing = closing.ok_or_else(|| validation("ticket front matter is not closed"))?;
    Ok((
        fields,
        lines[closing + 1..]
            .iter()
            .map(|line| line.to_string())
            .collect(),
    ))
}

/// `_rewrite_ticket`: replace, remove (`None`) or append front-matter keys.
pub fn rewrite_ticket(content: &[u8], updates: &[(String, Option<String>)]) -> Result<Vec<u8>> {
    let text = std::str::from_utf8(content)
        .map_err(|_| Error::value("'utf-8' codec can't decode the ticket"))?;
    let lines = pystr::splitlines(text);
    let closing = lines
        .iter()
        .enumerate()
        .skip(1)
        .find(|(_, line)| pystr::strip(line) == "---")
        .map(|(index, _)| index)
        .ok_or_else(|| validation("ticket front matter is not closed"))?;
    let lookup = |key: &str| updates.iter().find(|(name, _)| name == key);
    let mut rewritten: Vec<String> = vec![lines[0].to_string()];
    let mut handled: BTreeSet<&str> = BTreeSet::new();
    for line in &lines[1..closing] {
        let (key, separated, _) = pystr::partition(line, ":");
        let normalized = if separated { pystr::strip(key) } else { "" };
        match lookup(normalized) {
            Some((name, value)) => {
                handled.insert(name.as_str());
                if let Some(value) = value {
                    rewritten.push(format!("{normalized}: {value}"));
                }
            }
            None => rewritten.push(line.to_string()),
        }
    }
    for (key, value) in updates {
        if !handled.contains(key.as_str())
            && let Some(value) = value
        {
            rewritten.push(format!("{key}: {value}"));
        }
    }
    rewritten.extend(lines[closing..].iter().map(|line| line.to_string()));
    Ok(format!("{}\n", rewritten.join("\n").trim_end_matches('\n')).into_bytes())
}

/// `_append_run_log`: one `- **Run <id>** — <summary>` line under `## Run log`.
pub fn append_run_log(content: &[u8], run_id: i64, summary: &str) -> Result<Vec<u8>> {
    let text = std::str::from_utf8(content)
        .map_err(|_| Error::value("'utf-8' codec can't decode the ticket"))?;
    let mut text = rstrip(text).to_string();
    let entry = format!("- **Run {run_id}** — {summary}");
    if text.contains("## Run log") {
        text.push('\n');
    } else {
        text.push_str("\n\n## Run log\n\n");
    }
    text.push_str(&entry);
    text.push('\n');
    Ok(text.into_bytes())
}

static SPIKE_REPORT: LazyLock<fancy_regex::Regex> = LazyLock::new(|| {
    fancy_regex::Regex::new(r"(?ims)^## Spike report\s*\n.*?(?=^## |\z)")
        .expect("the spike report pattern compiles")
});

fn run_summary(outcome: &StructuredWorkerOutcome, merged_source_commit: &str) -> Result<String> {
    let verification = if outcome.verification.is_empty() {
        "No verification recorded.".to_string()
    } else {
        outcome.verification.join("; ")
    };
    let mut summary = format!(
        "reviewed source merge {merged_source_commit}: {} Verification: {verification}",
        outcome.summary
    );
    if summary.len() > MAX_SUMMARY_BYTES {
        // Valid outcome fields can exceed the ticket log's bound when combined.
        let suffix = "… [full evidence retained in structured outcome]";
        let mut limit = MAX_SUMMARY_BYTES - suffix.len();
        while !summary.is_char_boundary(limit) {
            limit -= 1;
        }
        summary = format!("{}{suffix}", rstrip(&summary[..limit]));
    }
    bounded_text(&summary, "run summary", MAX_SUMMARY_BYTES)
}

/// `_is_ticket_path`: a top-level `.orchestrator/<id>.md`.
pub fn is_ticket_path(path: &str) -> bool {
    path.strip_prefix(".orchestrator/")
        .is_some_and(|rest| path.ends_with(".md") && !rest.contains('/'))
}

/// `PurePosixPath(path).stem`.
fn path_stem(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    match name.rfind('.') {
        Some(index) if index > 0 && index < name.len() - 1 => name[..index].to_string(),
        _ => name.to_string(),
    }
}

/// `_is_lifecycle_path`: `.orchestrator` or `.relay`, or anything inside.
pub fn is_lifecycle_path(path: &str) -> bool {
    let replaced = path.replace('\\', "/");
    let mut normalized = pystr::strip(&replaced);
    while let Some(rest) = normalized.strip_prefix("./") {
        normalized = rest;
    }
    normalized == ".orchestrator"
        || normalized.starts_with(".orchestrator/")
        || normalized == ".relay"
        || normalized.starts_with(".relay/")
}

/// `_validate_source_path`: one changed path from an outcome.
pub fn validate_source_path(value: &Value) -> Result<String> {
    let raw = if value.truthy() {
        value.py_str()
    } else {
        String::new()
    };
    let replaced = raw.replace('\\', "/");
    let path = pystr::strip(&replaced);
    let parent = path
        .split('/')
        .filter(|part| !part.is_empty() && *part != ".")
        .any(|part| part == "..");
    if path.is_empty()
        || path.starts_with('/')
        || parent
        || path.chars().any(|character| (character as u32) < 32)
        || is_lifecycle_path(path)
    {
        return Err(validation(format!(
            "invalid source changed path: {}",
            pystr::repr(path)
        )));
    }
    Ok(path.to_string())
}

/// `_parse_list`: a front-matter `[a, b]` list.
pub fn parse_list(value: &str) -> Vec<String> {
    let mut value = pystr::strip(value);
    if value.is_empty() || value == "[]" {
        return Vec::new();
    }
    if value.starts_with('[') && value.ends_with(']') && value.len() >= 2 {
        value = &value[1..value.len() - 1];
    }
    value
        .split(',')
        .map(|item| pystr::strip_quotes(pystr::strip(item)))
        .filter(|item| !item.is_empty())
        .map(str::to_string)
        .collect()
}

fn safe_id<'v>(value: &'v str, label: &str) -> Result<&'v str> {
    let valid = (1..=160).contains(&value.chars().count())
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "_.:-".contains(character));
    if !valid {
        return Err(validation(format!(
            "invalid {label}: {}",
            pystr::repr(value)
        )));
    }
    Ok(value)
}

/// `_validate_provider`.
fn validate_provider(provider: &str) -> Result<()> {
    if provider != "codex" && provider != "claude" {
        return Err(validation(format!(
            "unsupported worker provider: {}",
            pystr::repr(provider)
        )));
    }
    Ok(())
}

fn is_oid(value: &str) -> bool {
    (value.len() == 40 || value.len() == 64)
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// `_bounded_text(value, ...)` for a JSON value: `str(value or "")`.
fn bounded_value(value: Option<&Value>, label: &str, maximum: usize) -> Result<String> {
    let text = match value {
        Some(value) if value.truthy() => value.py_str(),
        _ => String::new(),
    };
    bounded_text(&text, label, maximum)
}

/// `_bounded_text`: whitespace collapsed and stripped, required, bounded,
/// and free of credentials and private runtime content.
pub fn bounded_text(value: &str, label: &str, maximum: usize) -> Result<String> {
    let mut collapsed = String::with_capacity(value.len());
    let mut in_space = false;
    for character in value.chars() {
        if pystr::is_space(character) {
            if !in_space {
                collapsed.push(' ');
            }
            in_space = true;
        } else {
            collapsed.push(character);
            in_space = false;
        }
    }
    let text = pystr::strip(&collapsed).to_string();
    if text.is_empty() {
        return Err(validation(format!("{label} is required")));
    }
    if text.len() > maximum {
        return Err(validation(format!("{label} exceeds {maximum} bytes")));
    }
    store::reject_secrets(text.as_bytes(), label)?;
    let lowered = text.to_lowercase();
    if ["hidden reasoning", "raw transcript", "raw log", "tool output"]
        .iter()
        .any(|marker| lowered.contains(marker))
    {
        return Err(validation(format!(
            "{label} contains prohibited private runtime content"
        )));
    }
    Ok(text)
}

fn optional_bounded(value: Option<&Value>, maximum: usize) -> Result<Option<String>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(value) if pystr::strip(&value.py_str()).is_empty() => Ok(None),
        Some(value) => bounded_value(Some(value), "optional outcome field", maximum).map(Some),
    }
}

/// `json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`.
fn canonical_json(value: &Value) -> String {
    json::dumps_compact_sorted_unicode(value)
}

fn canonical_line(value: &Value) -> Vec<u8> {
    let mut line = canonical_json(value).into_bytes();
    line.push(b'\n');
    line
}

/// `_format_instant`: microseconds and `Z`.
pub fn format_instant(value: Instant) -> String {
    value.isoformat_micros_z()
}

/// `_registry_timestamp`: the record's `updated_at` as a Unix timestamp.
fn registry_timestamp(value: Option<&Value>) -> Result<f64> {
    let Some(Value::Str(text)) = value else {
        return Err(validation("registry record has no updated_at timestamp"));
    };
    match Instant::fromisoformat_z(text) {
        Err(error) if error.kind == ErrorKind::Value => Err(validation(
            "registry updated_at timestamp is invalid",
        )),
        Err(error) => Err(error),
        Ok(None) => Err(validation("registry updated_at timestamp has no offset")),
        Ok(Some(instant)) => Ok(instant.unix_micros() as f64 / 1e6),
    }
}

/// `_truthy`.
fn truthy(value: &str) -> bool {
    matches!(value.to_lowercase().as_str(), "true" | "yes" | "1")
}

/// `text.isdigit()` followed by `int(text)`: Unicode decimal digits only.
fn py_isdigit_int(text: &str) -> Option<i64> {
    if text.is_empty()
        || !text
            .chars()
            .all(|character| pystr::decimal_value(character).is_some())
    {
        return None;
    }
    pystr::int(text)
}

fn rstrip(text: &str) -> &str {
    text.trim_end_matches(pystr::is_space)
}

fn strings(values: &[String]) -> Value {
    Value::List(values.iter().map(|value| Value::Str(value.clone())).collect())
}

fn optional(value: &Option<String>) -> Value {
    value.clone().map_or(Value::Null, Value::Str)
}

fn optional_str(value: Option<&str>) -> Value {
    value.map_or(Value::Null, Value::from)
}

/// `f"{value}"` for an optional string: `None` when absent.
fn py_optional(value: &Option<String>) -> &str {
    value.as_deref().unwrap_or("None")
}

/// `repr(value)` for a JSON value or a missing key.
fn py_repr(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => "None".to_string(),
        Some(Value::Str(text)) => pystr::repr(text),
        Some(other) => other.py_str(),
    }
}

// -- files ------------------------------------------------------------------

/// `str(OSError)` for a failure on `path`: `[Errno N] <message>: '<path>'`.
fn os_error(error: &std::io::Error, path: &Path) -> String {
    let message = error.to_string();
    let message = match message.rfind(" (os error ") {
        Some(index) => message[..index].to_string(),
        None => message,
    };
    match error.raw_os_error() {
        Some(code) => format!(
            "[Errno {code}] {message}: {}",
            pystr::repr(&path.to_string_lossy())
        ),
        None => message,
    }
}

fn read_file(path: &Path) -> Result<Vec<u8>> {
    fs::read(path).map_err(|error| Error::new(ErrorKind::Io, os_error(&error, path)))
}

/// `path.read_text(encoding="utf-8")` for JSON: universal newlines.
fn read_text(bytes: &[u8]) -> Option<String> {
    std::str::from_utf8(bytes)
        .ok()
        .map(pystr::universal_newlines)
}

/// `json.loads(path.read_text())`, or the reason it failed.
fn read_json_file(path: &Path) -> std::result::Result<Value, String> {
    let bytes = fs::read(path).map_err(|error| os_error(&error, path))?;
    let text = read_text(&bytes)
        .ok_or_else(|| "'utf-8' codec can't decode the file".to_string())?;
    json::parse(&text).ok_or_else(|| "Expecting value".to_string())
}

/// `json.loads(bytes)`: UTF-8, or UTF-16/32 by `json.detect_encoding`.
fn decode_json_bytes(bytes: &[u8]) -> Option<Value> {
    json::parse(&store::decode_json_bytes(bytes)?)
}

/// `base64.b64decode(text, validate=True)`.
fn b64decode_validate(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    let body_end = bytes
        .iter()
        .position(|byte| *byte == b'=')
        .unwrap_or(bytes.len());
    let padding = &bytes[body_end..];
    if padding.len() > 2 || padding.iter().any(|byte| *byte != b'=') {
        return None;
    }
    let value = |byte: u8| -> Option<u32> {
        Some(match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u32)
    };
    let body = &bytes[..body_end];
    let digits = body.iter().map(|byte| value(*byte)).collect::<Option<Vec<_>>>()?;
    if bytes.len() % 4 != 0 || digits.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity(digits.len() * 3 / 4);
    for chunk in digits.chunks(4) {
        let mut accumulator = 0u32;
        for digit in chunk {
            accumulator = (accumulator << 6) | digit;
        }
        accumulator <<= 6 * (4 - chunk.len() as u32);
        let produced = chunk.len() * 6 / 8;
        for index in 0..produced {
            out.push((accumulator >> (16 - 8 * index)) as u8);
        }
    }
    Some(out)
}

/// `Path(path).resolve(strict=True)`; `None` where it raises.
fn strict_resolve(path: &str) -> Option<PathBuf> {
    let target = if path.is_empty() { "." } else { path };
    fs::canonicalize(target).ok()
}

fn is_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink())
}

fn create_dirs(path: &Path) -> Result<()> {
    fs::create_dir_all(path).map_err(|error| Error::new(ErrorKind::Io, os_error(&error, path)))
}

/// Write `content` beside `path` and rename it over `path`.
fn replace_with(path: &Path, content: &[u8]) -> Result<()> {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let temporary = path.with_file_name(format!("{name}.{}.tmp", store::random_hex()));
    fs::write(&temporary, content)
        .map_err(|error| Error::new(ErrorKind::Io, os_error(&error, &temporary)))?;
    fs::rename(&temporary, path).map_err(|error| Error::new(ErrorKind::Io, os_error(&error, path)))
}

/// The snapshot's files under `<workspace>/.orchestrator`, each `0444`, then
/// every directory `0555`.
fn write_read_only_tree(
    workspace_path: &Path,
    destination: &Path,
    selected: &BTreeMap<String, Vec<u8>>,
) -> std::result::Result<(), String> {
    for (relative, content) in selected {
        let target = workspace_path.join(relative);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|error| os_error(&error, parent))?;
        }
        let name = target
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let temporary = target.with_file_name(format!("{name}.{}.tmp", store::random_hex()));
        fs::write(&temporary, content).map_err(|error| os_error(&error, &temporary))?;
        fs::rename(&temporary, &target).map_err(|error| os_error(&error, &target))?;
        fs::set_permissions(&target, fs::Permissions::from_mode(0o444))
            .map_err(|error| os_error(&error, &target))?;
    }
    let mut directories = Vec::new();
    collect_directories(destination, &mut directories);
    directories.sort_by_key(|path| std::cmp::Reverse(path.components().count()));
    for directory in directories.iter().chain(std::iter::once(&destination.to_path_buf())) {
        fs::set_permissions(directory, fs::Permissions::from_mode(0o555))
            .map_err(|error| os_error(&error, directory))?;
    }
    Ok(())
}

/// Every real directory below `root`, not following symlinks.
fn collect_directories(root: &Path, into: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            into.push(path.clone());
            collect_directories(&path, into);
        }
    }
}

/// `root.rglob("*")` as `_validate_materialized_snapshot` reads it: every
/// non-directory must be a regular file; the manifest itself is left out.
fn collect_snapshot_files(root: &Path, directory: &Path, into: &mut BTreeSet<String>) -> Result<()> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Ok(());
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let symlink = entry.file_type().is_ok_and(|kind| kind.is_symlink());
        // `is_dir()` follows a symlink; `rglob` lists it but does not descend.
        if path.is_dir() {
            if !symlink {
                collect_snapshot_files(root, &path, into)?;
            }
            continue;
        }
        if symlink || !path.is_file() {
            return Err(validation(
                "immutable worker snapshot contains a non-regular file",
            ));
        }
        let relative = path
            .strip_prefix(root)
            .map(|relative| relative.to_string_lossy().into_owned())
            .unwrap_or_default();
        let relative = format!(".orchestrator/{relative}");
        if relative != SNAPSHOT_MANIFEST {
            into.insert(relative);
        }
    }
    Ok(())
}

/// `_make_writable`: add `rwx` for the owner throughout, without following
/// symlinks.
fn make_writable(path: &Path) {
    if is_symlink(path) || !path.exists() {
        return;
    }
    add_owner_bits(path);
    walk_writable(path);
}

fn add_owner_bits(path: &Path) {
    if let Ok(metadata) = fs::metadata(path) {
        let mode = metadata.permissions().mode() | 0o700;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(mode));
    }
}

fn walk_writable(directory: &Path) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    let mut directories = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let kind = entry.file_type();
        if kind.as_ref().is_ok_and(|kind| kind.is_symlink()) {
            continue;
        }
        add_owner_bits(&path);
        if kind.is_ok_and(|kind| kind.is_dir()) {
            directories.push(path);
        }
    }
    for path in directories {
        walk_writable(&path);
    }
}

// -- git and locks ---------------------------------------------------------

/// `_git_text`: `git -C <repo> <arguments>` in the caller's environment;
/// stripped stdout, or an `ArtifactValidationError` naming Git's message.
fn git_text(repo: &Path, arguments: &[&str]) -> Result<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(arguments)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| Error::new(ErrorKind::Io, error.to_string()))?;
    if !output.status.success() {
        return Err(validation(format!(
            "git {} failed: {}",
            arguments.join(" "),
            pystr::strip(&String::from_utf8_lossy(&output.stderr))
        )));
    }
    Ok(pystr::strip(&String::from_utf8_lossy(&output.stdout)).to_string())
}

fn git_is_ancestor(repo: &Path, ancestor: &str, descendant: &str) -> Result<bool> {
    let status = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["merge-base", "--is-ancestor", ancestor, descendant])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|error| Error::new(ErrorKind::Io, error.to_string()))?;
    Ok(status.success())
}

/// `_dirty_source_lines`: `git status` lines outside the lifecycle paths.
fn dirty_source_lines(workspace_path: &Path) -> Result<Vec<String>> {
    let status = git_text(
        workspace_path,
        &["status", "--porcelain=v1", "--untracked-files=all"],
    )?;
    Ok(pystr::splitlines(&status)
        .into_iter()
        .filter(|line| {
            let path: String = if line.chars().count() > 3 {
                line.chars().skip(3).collect()
            } else {
                line.to_string()
            };
            !is_lifecycle_path(&path)
        })
        .map(str::to_string)
        .collect())
}

static OUTCOME_LOCKS: LazyLock<Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// `_outcome_lock`: one in-process lock per outcome or proof path.
fn outcome_lock(path: &Path) -> Arc<Mutex<()>> {
    let mut locks = OUTCOME_LOCKS
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    Arc::clone(locks.entry(path.to_path_buf()).or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TICKET: &str = "---\nid: RR-1\ntitle: \"A ticket\"\nstatus: backlog\nrun_id: null\n---\n\n## Description\n\nBody.\n";

    #[test]
    fn split_reads_front_matter() {
        let (fields, body) = split_ticket(TICKET.as_bytes()).unwrap();
        assert_eq!(field(&fields, "title"), Some("A ticket"));
        assert_eq!(field(&fields, "run_id"), Some("null"));
        assert_eq!(body, vec!["", "## Description", "", "Body."]);
        assert_eq!(
            split_ticket(b"no front matter").unwrap_err().message,
            "ticket has no YAML front matter"
        );
        assert_eq!(
            split_ticket(b"---\nid: x\n").unwrap_err().message,
            "ticket front matter is not closed"
        );
    }

    #[test]
    fn rewrite_replaces_removes_and_appends() {
        let changes = updates(&[
            ("status", some("ready")),
            ("run_id", None),
            ("activity_at", some("2026-08-04T05:00:00.000000Z")),
        ]);
        let rewritten = String::from_utf8(rewrite_ticket(TICKET.as_bytes(), &changes).unwrap())
            .unwrap();
        assert_eq!(
            rewritten,
            "---\nid: RR-1\ntitle: \"A ticket\"\nstatus: ready\nactivity_at: 2026-08-04T05:00:00.000000Z\n---\n\n## Description\n\nBody.\n"
        );
    }

    #[test]
    fn run_log_is_appended() {
        let once = append_run_log(TICKET.as_bytes(), 3, "first").unwrap();
        let twice = append_run_log(&once, 4, "second").unwrap();
        assert!(
            String::from_utf8(twice)
                .unwrap()
                .ends_with("Body.\n\n## Run log\n\n- **Run 3** — first\n- **Run 4** — second\n")
        );
    }

    #[test]
    fn bounded_text_collapses_and_refuses() {
        assert_eq!(bounded_text("  a \n\t b ", "x", 10).unwrap(), "a b");
        assert_eq!(bounded_text(" ", "x", 10).unwrap_err().message, "x is required");
        assert_eq!(
            bounded_text("abcdefghijk", "x", 10).unwrap_err().message,
            "x exceeds 10 bytes"
        );
        assert_eq!(
            bounded_text("the Raw Transcript", "x", 100)
                .unwrap_err()
                .message,
            "x contains prohibited private runtime content"
        );
    }

    #[test]
    fn source_paths_and_lifecycle_paths() {
        assert_eq!(
            validate_source_path(&Value::from(" src\\a.rs ")).unwrap(),
            "src/a.rs"
        );
        for bad in ["", "/abs", "a/../b", ".orchestrator/x", "./.relay", "a\u{1}b"] {
            assert!(validate_source_path(&Value::from(bad)).is_err(), "{bad}");
        }
        assert!(is_lifecycle_path("././.orchestrator"));
        assert!(!is_lifecycle_path(".orchestratorx"));
    }

    #[test]
    fn lists_ids_and_base64() {
        assert_eq!(parse_list("[RR-1, 'RR-2', \"\"]"), vec!["RR-1", "RR-2"]);
        assert!(parse_list(" [] ").is_empty());
        assert!(safe_id("RR-1:x.y_z", "ticket ID").is_ok());
        assert_eq!(
            safe_id("bad id", "ticket ID").unwrap_err().message,
            "invalid ticket ID: 'bad id'"
        );
        assert_eq!(b64decode_validate("eyJ2IjoxfQ==").unwrap(), b"{\"v\":1}");
        assert_eq!(b64decode_validate("YWJj").unwrap(), b"abc");
        assert!(b64decode_validate("YWJ").is_none());
        assert!(b64decode_validate("YW*j").is_none());
        assert!(b64decode_validate("YQ=a").is_none());
        assert_eq!(path_stem(".orchestrator/RR-1.md"), "RR-1");
        assert_eq!(py_isdigit_int("12"), Some(12));
        assert_eq!(py_isdigit_int("+12"), None);
    }

    #[test]
    fn spike_report_section_is_replaced() {
        let text = "---\nid: X\n---\n\n## Spike report\n\nold\n\n## Run log\n\n- x\n";
        assert_eq!(
            SPIKE_REPORT.replace_all(text, "").into_owned(),
            "---\nid: X\n---\n\n## Run log\n\n- x\n"
        );
    }
}
