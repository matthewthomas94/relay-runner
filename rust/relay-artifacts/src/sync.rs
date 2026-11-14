//! `services/artifact_sync.py`: exact-ref, no-force synchronization of one
//! project's `refs/heads/relay/artifacts` with one explicitly configured
//! remote.
//!
//! The remote ref is always fetched into a throwaway bare quarantine first
//! and its whole history verified there (orphan root, linear history, every
//! path and blob, every note catalog, the config's identity) before its
//! objects reach the project repository under a scratch ref. Pushes are
//! normal pushes, never forced; a prepared archival publication carries a
//! lease on the exact verified base. Every result is persisted to
//! `<project state>/sync-state.json` and the last fully verified remote head
//! to `remote-history-verification.json`, in Python's exact forms, so a
//! Python and a Rust engine can alternate on one data root and one remote.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256::hex_digest;

use crate::store::{
    ArtifactStore, Entries, FailureInjector, TreeEntry, parse_trailers, validate_actor,
    validate_allowlisted_path, validate_event_id,
};
use crate::{Error, ErrorKind, Result, git, pystr, toml};

/// `ArtifactSyncMode`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SyncMode {
    LocalOnly,
    Enabled,
    Paused,
}

impl SyncMode {
    pub fn value(self) -> &'static str {
        match self {
            SyncMode::LocalOnly => "local_only",
            SyncMode::Enabled => "enabled",
            SyncMode::Paused => "paused",
        }
    }

    /// `ArtifactSyncMode(value)`; `None` where Python raises `ValueError`.
    pub fn from_value(value: &str) -> Option<Self> {
        Some(match value {
            "local_only" => SyncMode::LocalOnly,
            "enabled" => SyncMode::Enabled,
            "paused" => SyncMode::Paused,
            _ => return None,
        })
    }
}

/// `ArtifactSyncState`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SyncState {
    LocalOnly,
    Paused,
    Clean,
    Ahead,
    Behind,
    Syncing,
    RetryableOffline,
    RetryableAuth,
    RetryableRemoteRace,
    MissingRemoteRef,
    ProtectedRef,
    ForeignRef,
    LocalAheadBlocked,
    Conflict,
    Failed,
}

impl SyncState {
    pub fn value(self) -> &'static str {
        match self {
            SyncState::LocalOnly => "local_only",
            SyncState::Paused => "paused",
            SyncState::Clean => "clean",
            SyncState::Ahead => "ahead",
            SyncState::Behind => "behind",
            SyncState::Syncing => "syncing",
            SyncState::RetryableOffline => "retryable_offline",
            SyncState::RetryableAuth => "retryable_auth",
            SyncState::RetryableRemoteRace => "retryable_remote_race",
            SyncState::MissingRemoteRef => "missing_remote_ref",
            SyncState::ProtectedRef => "protected_ref",
            SyncState::ForeignRef => "foreign_ref",
            SyncState::LocalAheadBlocked => "local_ahead_fail_closed",
            SyncState::Conflict => "conflict",
            SyncState::Failed => "failed",
        }
    }

    /// `ArtifactSyncState(value)`; `None` where Python raises `ValueError`.
    pub fn from_value(value: &str) -> Option<Self> {
        ALL_STATES
            .iter()
            .copied()
            .find(|state| state.value() == value)
    }
}

const ALL_STATES: [SyncState; 15] = [
    SyncState::LocalOnly,
    SyncState::Paused,
    SyncState::Clean,
    SyncState::Ahead,
    SyncState::Behind,
    SyncState::Syncing,
    SyncState::RetryableOffline,
    SyncState::RetryableAuth,
    SyncState::RetryableRemoteRace,
    SyncState::MissingRemoteRef,
    SyncState::ProtectedRef,
    SyncState::ForeignRef,
    SyncState::LocalAheadBlocked,
    SyncState::Conflict,
    SyncState::Failed,
];

/// `ArtifactConflict`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Conflict {
    pub path: String,
    pub kind: String,
    pub base_oid: Option<String>,
    pub local_oid: Option<String>,
    pub remote_oid: Option<String>,
    pub recovery: String,
}

impl Conflict {
    /// `dataclasses.asdict(conflict)`.
    pub fn as_dict(&self) -> Dict {
        let mut value = Dict::new();
        value.insert("path", self.path.as_str());
        value.insert("kind", self.kind.as_str());
        value.insert("base_oid", optional(&self.base_oid));
        value.insert("local_oid", optional(&self.local_oid));
        value.insert("remote_oid", optional(&self.remote_oid));
        value.insert("recovery", self.recovery.as_str());
        value
    }
}

/// `ArtifactConflictReport`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConflictReport {
    pub project_id: String,
    pub merge_base: String,
    pub local_head: String,
    pub remote_head: String,
    pub local_events: Vec<(String, String)>,
    pub conflicts: Vec<Conflict>,
}

/// `ArtifactSyncResult`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncResult {
    pub state: SyncState,
    pub observed_state: SyncState,
    pub transitions: Vec<SyncState>,
    pub attempts: i64,
    pub local_head: Option<String>,
    pub remote_head: Option<String>,
    pub recovery: Option<String>,
    pub conflict_report: Option<ConflictReport>,
}

/// `ArtifactRemoteProof`: one archived object that must survive an
/// independent remote fetch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteProof {
    pub source_commit: String,
    pub path: String,
    pub blob_id: String,
    pub sha256: String,
}

/// One conflict decision: `local`, `remote`, `delete`, or merged bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    Keyword(String),
    Bytes(Vec<u8>),
}

/// The constructor's keyword arguments other than the store.
pub struct SyncOptions {
    pub mode: SyncMode,
    pub remote_name: Option<String>,
    pub max_attempts: i64,
    pub base_retry_seconds: f64,
    pub sleep: Box<dyn Fn(f64) + Send + Sync>,
    pub jitter: Box<dyn Fn() -> f64 + Send + Sync>,
    pub failure_injector: Option<FailureInjector>,
}

impl SyncOptions {
    /// Python's defaults for `mode` and `remote_name`: three attempts, a
    /// 0.25 s base retry, `time.sleep` and `random.random`.
    pub fn new(mode: SyncMode, remote_name: Option<&str>) -> Self {
        Self {
            mode,
            remote_name: remote_name.map(str::to_string),
            max_attempts: 3,
            base_retry_seconds: 0.25,
            sleep: Box::new(|seconds| {
                if seconds > 0.0 {
                    std::thread::sleep(std::time::Duration::from_secs_f64(seconds));
                }
            }),
            jitter: Box::new(random_unit),
            failure_injector: None,
        }
    }
}

/// `random.random()`: a uniform float in `[0, 1)` with 53 random bits.
pub fn random_unit() -> f64 {
    let mut bytes = [0u8; 8];
    let read = File::open("/dev/urandom").and_then(|mut source| source.read_exact(&mut bytes));
    if read.is_err() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.subsec_nanos());
        bytes = u64::from(nanos)
            .wrapping_mul(0x9E37_79B9_7F4A_7C15)
            .to_le_bytes();
    }
    (u64::from_le_bytes(bytes) >> 11) as f64 / (1u64 << 53) as f64
}

/// `recover_exact_ref`'s `validate_head` callback.
pub type ValidateHead<'v> = &'v dyn Fn(&str) -> Result<()>;

/// `_RemoteSnapshot`.
struct RemoteSnapshot {
    head: Option<String>,
    quarantine: Option<PathBuf>,
    error_state: Option<SyncState>,
    recovery: Option<String>,
}

impl RemoteSnapshot {
    fn error(
        head: Option<String>,
        quarantine: Option<PathBuf>,
        state: SyncState,
        recovery: impl Into<String>,
    ) -> Self {
        Self {
            head,
            quarantine,
            error_state: Some(state),
            recovery: Some(recovery.into()),
        }
    }
}

/// `_rebase_unpublished`'s three outcomes.
enum Replay {
    Commit(String),
    Blocked(String),
    Conflict(ConflictReport),
}

type Tree = BTreeMap<String, TreeEntry>;

fn validation(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::Validation, message)
}

fn concurrent(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::ConcurrentUpdate, message)
}

fn optional(value: &Option<String>) -> Value {
    value.clone().map_or(Value::Null, Value::Str)
}

fn is_oid(value: &str) -> bool {
    (value.len() == 40 || value.len() == 64) && is_lower_hex(value)
}

fn is_lower_hex(value: &str) -> bool {
    value
        .bytes()
        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64 && is_lower_hex(value)
}

/// Python's `repr` of an optional TOML value.
fn toml_repr(value: Option<&toml::Value>) -> String {
    value.map_or_else(|| "None".to_string(), toml::Value::py_repr)
}

/// A Python list of strings' `repr`.
fn list_repr(values: &[&String]) -> String {
    let items: Vec<String> = values.iter().map(|value| pystr::repr(value)).collect();
    format!("[{}]", items.join(", "))
}

fn tree_of(entries: Entries) -> Tree {
    entries.into_iter().collect()
}

fn oid_of(tree: &Tree, path: &str) -> Option<String> {
    tree.get(path).map(|entry| entry.oid.clone())
}

/// A fresh `tempfile.mkdtemp(prefix=...)` directory.
fn make_temporary_directory(prefix: &str) -> Result<PathBuf> {
    let base = std::env::temp_dir();
    for _ in 0..100 {
        let suffix: String = (0..8)
            .map(|_| {
                let alphabet = b"abcdefghijklmnopqrstuvwxyz0123456789_";
                alphabet[(random_unit() * alphabet.len() as f64) as usize % alphabet.len()] as char
            })
            .collect();
        let path = base.join(format!("{prefix}{suffix}"));
        match fs::create_dir(&path) {
            Ok(()) => return Ok(path),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Err(Error::new(
        ErrorKind::Io,
        "No usable temporary directory name found",
    ))
}

/// `git -C <repository> <arguments>` with the store's environment and any
/// exit status.
fn quarantine_process(repository: &Path, arguments: &[&str]) -> Result<git::Output> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(arguments)
        .env_clear()
        .envs(git::environment(&[]))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| Error::new(ErrorKind::Io, format!("git could not start: {error}")))?;
    Ok(git::Output {
        status: output.status.code().unwrap_or(-1),
        stdout: output.stdout,
        stderr: output.stderr,
    })
}

/// `ArtifactSyncEngine`.
pub struct ArtifactSyncEngine<'s> {
    pub store: &'s ArtifactStore,
    pub mode: SyncMode,
    pub remote_name: Option<String>,
    pub max_attempts: i64,
    pub base_retry_seconds: f64,
    pub state_path: PathBuf,
    sleep: Box<dyn Fn(f64) + Send + Sync>,
    jitter: Box<dyn Fn() -> f64 + Send + Sync>,
    failure_injector: Option<FailureInjector>,
}

impl<'s> ArtifactSyncEngine<'s> {
    pub fn new(store: &'s ArtifactStore, options: SyncOptions) -> Result<Self> {
        let remote_name = options.remote_name;
        if options.mode == SyncMode::Enabled && remote_name.as_deref().is_none_or(str::is_empty) {
            return Err(validation(
                "sync requires an explicitly selected existing remote or Local only",
            ));
        }
        if options.mode == SyncMode::LocalOnly && remote_name.is_some() {
            return Err(validation("Local only cannot carry an inferred remote"));
        }
        if let Some(name) = &remote_name
            && !is_remote_name(name)
        {
            return Err(validation(format!(
                "invalid configured remote name: {}",
                pystr::repr(name)
            )));
        }
        Ok(Self {
            store,
            mode: options.mode,
            remote_name,
            max_attempts: options.max_attempts.clamp(1, 8),
            base_retry_seconds: options.base_retry_seconds.max(0.0),
            state_path: store.project_state.join("sync-state.json"),
            sleep: options.sleep,
            jitter: options.jitter,
            failure_injector: options.failure_injector,
        })
    }

    pub fn status(&self) -> Result<SyncResult> {
        match self.mode {
            SyncMode::LocalOnly => self.finish(
                SyncState::LocalOnly,
                SyncState::LocalOnly,
                0,
                self.store.head()?,
                None,
                None,
                None,
                &[SyncState::LocalOnly],
            ),
            SyncMode::Paused => self.finish(
                SyncState::Paused,
                SyncState::Paused,
                0,
                self.store.head()?,
                None,
                None,
                None,
                &[SyncState::Paused],
            ),
            SyncMode::Enabled => self.synchronize(false, None, None),
        }
    }

    pub fn sync(&self) -> Result<SyncResult> {
        if self.mode != SyncMode::Enabled {
            return self.status();
        }
        self.synchronize(true, None, None)
    }

    /// Synchronize through only the exposure-confirmed destinations.
    pub fn sync_confirmed(
        &self,
        expected_remote_url_sha256: &str,
        expected_push_url_sha256: &str,
    ) -> Result<SyncResult> {
        if self.mode != SyncMode::Enabled {
            return Err(validation("confirmed sync requires enabled remote sync"));
        }
        self.synchronize(
            true,
            Some(expected_remote_url_sha256),
            Some(expected_push_url_sha256),
        )
    }

    /// Create a missing remote artifact ref only after explicit confirmation.
    pub fn publish_initial(&self, confirmed: bool) -> Result<SyncResult> {
        if self.mode != SyncMode::Enabled {
            return self.status();
        }
        let Some(local_head) = self.store.head()? else {
            return Err(validation("artifact store is not initialized"));
        };
        self.validate_configuration(&local_head)?;
        if !confirmed {
            return self.finish(
                SyncState::MissingRemoteRef,
                SyncState::MissingRemoteRef,
                0,
                Some(local_head),
                None,
                Some("Confirm the first normal push or choose Local only.".to_string()),
                None,
                &[SyncState::MissingRemoteRef],
            );
        }
        let early = self.with_remote_snapshot(None, |remote| {
            if remote
                .error_state
                .is_some_and(|state| state != SyncState::MissingRemoteRef)
            {
                return self
                    .remote_error_result(remote, Some(local_head.clone()), 1)
                    .map(Some);
            }
            if remote.head.is_some() {
                return self.sync().map(Some);
            }
            Ok(None)
        })?;
        if let Some(result) = early {
            return Ok(result);
        }
        if let Some(blocked) = self.validate_local_commits(None, &local_head)? {
            return self.finish(
                SyncState::LocalAheadBlocked,
                SyncState::Ahead,
                1,
                Some(local_head),
                None,
                Some(blocked),
                None,
                &[SyncState::Ahead, SyncState::LocalAheadBlocked],
            );
        }
        if let Some((state, recovery)) = self.push(&local_head, None, None)? {
            return self.finish(
                state,
                SyncState::Ahead,
                1,
                Some(local_head),
                None,
                Some(recovery),
                None,
                &[SyncState::Ahead, SyncState::Syncing, state],
            );
        }
        self.finish(
            SyncState::Clean,
            SyncState::Ahead,
            1,
            Some(local_head.clone()),
            Some(local_head),
            None,
            None,
            &[SyncState::Ahead, SyncState::Syncing, SyncState::Clean],
        )
    }

    /// Normally publish a prepared descendant, then independently refetch it.
    ///
    /// The local artifact ref is deliberately left at `expected_remote_head`;
    /// a caller may advance it only after this returns `Clean`. A failed or
    /// indeterminate push is always resolved by another exact-ref quarantine
    /// fetch rather than by trusting the push exit status.
    pub fn publish_prepared(
        &self,
        candidate_head: &str,
        expected_remote_head: &str,
        proofs: &[RemoteProof],
        expected_remote_url_sha256: Option<&str>,
        expected_push_url_sha256: Option<&str>,
    ) -> Result<SyncResult> {
        if self.mode != SyncMode::Enabled {
            return Err(validation(
                "prepared publication requires enabled remote sync",
            ));
        }
        let candidate = candidate_head.to_string();
        self.store.with_writer_lock(|| {
            let local_head = self.store.head()?;
            if local_head.as_deref() != Some(expected_remote_head) {
                return Err(concurrent(
                    "local artifact authority changed before prepared publication",
                ));
            }
            self.validate_configuration(expected_remote_head)?;
            self.store.validate_artifact_head(candidate_head)?;
            if self.store.first_parent(candidate_head)?.as_deref() != Some(expected_remote_head) {
                return Err(validation(
                    "prepared artifact commit is not a direct descendant of the verified base",
                ));
            }
            if let Some(blocked) =
                self.validate_local_commits(Some(expected_remote_head), candidate_head)?
            {
                return self.finish(
                    SyncState::LocalAheadBlocked,
                    SyncState::Ahead,
                    0,
                    Some(candidate.clone()),
                    None,
                    Some(blocked),
                    None,
                    &[SyncState::Ahead, SyncState::LocalAheadBlocked],
                );
            }

            let early = self.with_remote_snapshot(expected_remote_url_sha256, |before| {
                if before.error_state.is_some() {
                    return self
                        .remote_error_result(before, Some(candidate.clone()), 1)
                        .map(Some);
                }
                let (head, quarantine) = snapshot_parts(before);
                if self.quarantine_is_ancestor(quarantine, candidate_head, head) {
                    return self
                        .verified_prepared_result(before, candidate_head, proofs, 1)
                        .map(Some);
                }
                if head != expected_remote_head {
                    let observed = self.relationship(expected_remote_head, head)?;
                    return self
                        .finish(
                            observed,
                            observed,
                            1,
                            Some(candidate.clone()),
                            Some(head.to_string()),
                            Some(
                                "The configured artifact ref changed before archival publication; \
                                 reconcile and retry without force."
                                    .to_string(),
                            ),
                            None,
                            &[observed],
                        )
                        .map(Some);
                }
                Ok(None)
            })?;
            if let Some(result) = early {
                return Ok(result);
            }

            self.inject("before_prepared_push")?;
            let push_destination = match expected_push_url_sha256 {
                Some(expected) => Some(self.validated_push_destination(expected)?),
                None => None,
            };
            let push_error = self.push(
                candidate_head,
                push_destination.as_deref(),
                Some(expected_remote_head),
            )?;
            self.inject("after_prepared_push")?;

            // A new quarantine, not the preflight snapshot: it resolves
            // indeterminate pushes and remote races.
            self.with_remote_snapshot(expected_remote_url_sha256, |after| {
                if let Some(error_state) = after.error_state {
                    if error_state == SyncState::MissingRemoteRef {
                        return self.finish(
                            SyncState::RetryableRemoteRace,
                            SyncState::MissingRemoteRef,
                            1,
                            Some(candidate.clone()),
                            None,
                            Some(
                                "The remote artifact ref was deleted after archival preflight; \
                                 restore the exact verified base and retry. Relay did not recreate it."
                                    .to_string(),
                            ),
                            None,
                            &[
                                SyncState::Ahead,
                                SyncState::Syncing,
                                SyncState::RetryableRemoteRace,
                            ],
                        );
                    }
                    return self.remote_error_result(after, Some(candidate.clone()), 1);
                }
                let (head, quarantine) = snapshot_parts(after);
                if self.quarantine_is_ancestor(quarantine, candidate_head, head) {
                    return self.verified_prepared_result(after, candidate_head, proofs, 1);
                }
                if head != expected_remote_head {
                    return self.finish(
                        SyncState::RetryableRemoteRace,
                        self.relationship(expected_remote_head, head)?,
                        1,
                        Some(candidate.clone()),
                        Some(head.to_string()),
                        Some(
                            "The remote artifact ref changed after archival preflight; restore or \
                             reconcile the exact verified base and retry. Relay did not overwrite it."
                                .to_string(),
                        ),
                        None,
                        &[
                            SyncState::Ahead,
                            SyncState::Syncing,
                            SyncState::RetryableRemoteRace,
                        ],
                    );
                }
                if let Some((state, recovery)) = &push_error {
                    return self.finish(
                        *state,
                        SyncState::Ahead,
                        1,
                        Some(candidate.clone()),
                        Some(head.to_string()),
                        Some(recovery.clone()),
                        None,
                        &[SyncState::Ahead, SyncState::Syncing, *state],
                    );
                }
                self.finish(
                    SyncState::Failed,
                    SyncState::Ahead,
                    1,
                    Some(candidate.clone()),
                    Some(head.to_string()),
                    Some(
                        "The remote did not retain the prepared artifact commit after push; \
                         the local materialization remains authoritative."
                            .to_string(),
                    ),
                    None,
                    &[SyncState::Ahead, SyncState::Syncing, SyncState::Failed],
                )
            })
        })
    }

    /// Import the artifact ref only from the exposure-confirmed fetch URL.
    pub fn recover_exact_ref(
        &self,
        expected_remote_url_sha256: &str,
        validate_head: Option<ValidateHead<'_>>,
    ) -> Result<SyncResult> {
        if self.mode != SyncMode::Enabled {
            return Err(validation("remote recovery requires enabled remote sync"));
        }
        self.store.with_writer_lock(|| {
            let current = self.store.head()?;
            if let Some(current) = &current {
                self.validate_configuration(current)?;
                if let Err(error) = self.store.ensure_materialization_consistent(current) {
                    if error.kind != ErrorKind::MaterializationConflict {
                        return Err(error);
                    }
                    return self.finish(
                        SyncState::Failed,
                        SyncState::Failed,
                        0,
                        Some(current.clone()),
                        None,
                        Some(format!(
                            "Local artifact materialization must be preserved: {error}"
                        )),
                        None,
                        &[SyncState::Failed],
                    );
                }
            } else if self.store.materialized_path.exists()
                || fs::symlink_metadata(&self.store.materialized_path).is_ok()
            {
                return self.finish(
                    SyncState::Failed,
                    SyncState::Failed,
                    0,
                    None,
                    None,
                    Some(
                        "Fresh artifact recovery will not replace an existing .orchestrator tree; \
                         review or migrate it explicitly."
                            .to_string(),
                    ),
                    None,
                    &[SyncState::Failed],
                );
            }

            self.inject("before_recovery_fetch")?;
            self.with_remote_snapshot(Some(expected_remote_url_sha256), |remote| {
                if remote.error_state.is_some() {
                    return self.remote_error_result(remote, current.clone(), 1);
                }
                let head = remote.head.clone().unwrap_or_default();
                if let Some(validate) = validate_head
                    && let Err(error) = validate(&head)
                {
                    if !is_store_or_value_error(error.kind) {
                        return Err(error);
                    }
                    return self.finish(
                        SyncState::Failed,
                        SyncState::Failed,
                        1,
                        current.clone(),
                        Some(head.clone()),
                        Some(format!(
                            "Remote artifact recovery validation failed: {error}"
                        )),
                        None,
                        &[SyncState::Syncing, SyncState::Failed],
                    );
                }
                if let Some(local) = &current
                    && *local != head
                    && !self.is_ancestor(local, &head)?
                {
                    return self.finish(
                        SyncState::Conflict,
                        SyncState::Conflict,
                        1,
                        current.clone(),
                        Some(head.clone()),
                        Some(
                            "Local and remote artifact authorities diverged; reconcile them \
                             explicitly before second-device recovery."
                                .to_string(),
                        ),
                        None,
                        &[SyncState::Conflict],
                    );
                }
                if current.as_deref() != Some(head.as_str()) {
                    let old = match &current {
                        Some(local) => local.clone(),
                        None => self.store.zero_oid()?,
                    };
                    let update = self.store.git(
                        &["update-ref", &self.store.artifact_ref, &head, &old],
                        &[],
                        None,
                        &[0, 128],
                    )?;
                    if update.status != 0 {
                        return self.finish(
                            SyncState::Ahead,
                            SyncState::Ahead,
                            1,
                            self.store.head()?,
                            Some(head.clone()),
                            Some(
                                "Local artifact authority changed during recovery; retry."
                                    .to_string(),
                            ),
                            None,
                            &[SyncState::Ahead],
                        );
                    }
                }
                self.inject("after_recovery_ref_update")?;
                let materialized = self
                    .store
                    .ensure_materialization_consistent(&head)
                    .and_then(|()| self.store.materialize(&head, false));
                if let Err(error) = materialized {
                    if error.kind != ErrorKind::MaterializationConflict {
                        return Err(error);
                    }
                    return self.finish(
                        SyncState::Failed,
                        SyncState::Failed,
                        1,
                        self.store.head()?,
                        Some(head.clone()),
                        Some(format!(
                            "Local artifact materialization must be preserved: {error}"
                        )),
                        None,
                        &[SyncState::Syncing, SyncState::Failed],
                    );
                }
                self.finish(
                    SyncState::Clean,
                    SyncState::Clean,
                    1,
                    Some(head.clone()),
                    Some(head.clone()),
                    None,
                    None,
                    &[SyncState::Syncing, SyncState::Clean],
                )
            })
        })
    }

    /// Import verified artifact-ref history without changing local authority.
    pub fn fetch_historical_object(
        &self,
        commit_id: &str,
        expected_remote_url_sha256: &str,
    ) -> Result<()> {
        if self.mode != SyncMode::Enabled {
            return Err(validation("historical fetch requires enabled remote sync"));
        }
        if !((commit_id.len() == 40 || commit_id.len() == 64) && is_lower_hex(commit_id)) {
            return Err(validation("historical commit identity is invalid"));
        }
        self.with_remote_snapshot(Some(expected_remote_url_sha256), |remote| {
            if remote.error_state.is_some() {
                return Err(validation(
                    remote
                        .recovery
                        .clone()
                        .filter(|recovery| !recovery.is_empty())
                        .unwrap_or_else(|| "historical artifact fetch failed".to_string()),
                ));
            }
            let found = self.store.git(
                &["cat-file", "-e", &format!("{commit_id}^{{commit}}")],
                &[],
                None,
                &[0, 128],
            )?;
            if found.status != 0 {
                return Err(validation(
                    "the confirmed artifact ref does not contain the requested historical commit",
                ));
            }
            let (head, quarantine) = snapshot_parts(remote);
            if !self.quarantine_is_ancestor(quarantine, commit_id, head) {
                return Err(validation(
                    "the requested historical commit is not reachable from the confirmed artifact ref",
                ));
            }
            Ok(())
        })
    }

    /// Publish an explicit three-way resolution as a normal fast-forward
    /// commit. Decisions are `local`, `remote`, `delete`, or caller-supplied
    /// merged bytes for every conflicting path; the commit records each
    /// reconciled event ID and digest so retries stay idempotent.
    pub fn resolve_conflict(
        &self,
        report: &ConflictReport,
        decisions: &[(String, Decision)],
        resolution_event_id: &str,
        device_id: &str,
        actor_type: &str,
        provider: Option<&str>,
    ) -> Result<SyncResult> {
        if self.mode != SyncMode::Enabled {
            return Err(validation("conflict resolution requires enabled sync"));
        }
        validate_event_id(resolution_event_id, "resolution event ID")?;
        validate_event_id(device_id, "device ID")?;
        validate_actor(actor_type)?;
        if let Some(name) = provider
            && name != "codex"
            && name != "claude"
        {
            return Err(validation(format!(
                "unsupported provider metadata: {}",
                pystr::repr(name)
            )));
        }
        if report.project_id != self.store.project_id {
            return Err(Error::new(
                ErrorKind::Identity,
                "conflict report belongs to another project",
            ));
        }
        if report
            .conflicts
            .iter()
            .any(|conflict| conflict.kind == "unrelated_history")
        {
            return Err(validation(
                "unrelated artifact histories require explicit identity-preserving recovery",
            ));
        }
        let decisions: BTreeMap<String, Decision> = decisions.iter().cloned().collect();
        let required: BTreeSet<&String> = report.conflicts.iter().map(|item| &item.path).collect();
        let given: BTreeSet<&String> = decisions.keys().collect();
        if given != required {
            let missing: Vec<&String> = required.difference(&given).copied().collect();
            let extra: Vec<&String> = given.difference(&required).copied().collect();
            return Err(validation(format!(
                "resolution must decide every conflict exactly once; missing={}, extra={}",
                list_repr(&missing),
                list_repr(&extra)
            )));
        }
        self.store.with_writer_lock(|| {
            if self.store.head()?.as_deref() != Some(report.local_head.as_str()) {
                return Err(concurrent(
                    "local artifact head changed since conflict review",
                ));
            }
            let early = self.with_remote_snapshot(None, |remote| {
                if remote.error_state.is_some() {
                    return self
                        .remote_error_result(remote, Some(report.local_head.clone()), 1)
                        .map(Some);
                }
                if remote.head.as_deref() != Some(report.remote_head.as_str()) {
                    return Err(concurrent(
                        "remote artifact head changed since conflict review",
                    ));
                }
                Ok(None)
            })?;
            if let Some(result) = early {
                return Ok(result);
            }
            self.store
                .ensure_materialization_consistent(&report.local_head)?;
            let final_entries = self.resolved_entries(report, &decisions)?;
            let tree_id = self.write_tree(&final_entries)?;
            let digest = resolution_digest(report, &decisions);
            let message = self.resolution_message(
                report,
                resolution_event_id,
                &digest,
                device_id,
                actor_type,
                provider,
            );
            let commit_id = self
                .store
                .git(
                    &["commit-tree", &tree_id, "-p", &report.remote_head],
                    &[],
                    Some(message.as_bytes()),
                    &[0],
                )?
                .line();
            let update = self.store.git(
                &[
                    "update-ref",
                    &self.store.artifact_ref,
                    &commit_id,
                    &report.local_head,
                ],
                &[],
                None,
                &[0, 128],
            )?;
            if update.status != 0 {
                return Err(concurrent(
                    "local artifact CAS failed during conflict resolution",
                ));
            }
            if let Some((state, recovery)) = self.push(&commit_id, None, None)? {
                self.store.materialize(&commit_id, false)?;
                return self.finish(
                    state,
                    SyncState::Conflict,
                    1,
                    Some(commit_id.clone()),
                    Some(report.remote_head.clone()),
                    Some(recovery),
                    None,
                    &[SyncState::Conflict, SyncState::Syncing, state],
                );
            }
            self.store.materialize(&commit_id, false)?;
            self.finish(
                SyncState::Clean,
                SyncState::Conflict,
                1,
                Some(commit_id.clone()),
                Some(commit_id.clone()),
                None,
                None,
                &[SyncState::Conflict, SyncState::Syncing, SyncState::Clean],
            )
        })
    }

    fn synchronize(
        &self,
        publish: bool,
        expected_remote_url_sha256: Option<&str>,
        expected_push_url_sha256: Option<&str>,
    ) -> Result<SyncResult> {
        let Some(local_head) = self.store.head()? else {
            return Err(validation("artifact store is not initialized"));
        };
        self.validate_configuration(&local_head)?;
        let mut last_result = None;
        for attempt in 1..=self.max_attempts {
            // Fetch and full-history verification are read-only with respect
            // to the canonical ref, so they must not delay local writes.
            let result = self.with_remote_snapshot(expected_remote_url_sha256, |remote| {
                if remote.error_state.is_some() {
                    self.store.with_writer_lock(|| {
                        let head = self.store.head()?.or_else(|| Some(local_head.clone()));
                        self.remote_error_result(remote, head, attempt)
                    })
                } else {
                    self.sync_once(
                        remote.head.as_deref().unwrap_or_default(),
                        publish,
                        attempt,
                        expected_push_url_sha256,
                    )
                }
            })?;
            let retryable = matches!(
                result.state,
                SyncState::RetryableOffline | SyncState::RetryableAuth | SyncState::Ahead
            );
            if !retryable || !publish || attempt >= self.max_attempts {
                return Ok(result);
            }
            last_result = Some(result);
            let mut delay = self.base_retry_seconds * 2f64.powi((attempt - 1) as i32);
            delay *= 0.75 + (self.jitter)() * 0.5;
            (self.sleep)(delay);
        }
        last_result.ok_or_else(|| Error::new(ErrorKind::Runtime, "no synchronization attempt"))
    }

    fn sync_once(
        &self,
        remote_head: &str,
        publish: bool,
        attempt: i64,
        expected_push_url_sha256: Option<&str>,
    ) -> Result<SyncResult> {
        enum Plan {
            Done(Box<SyncResult>),
            Publish {
                candidate: String,
                observed: SyncState,
                transitions: Vec<SyncState>,
            },
        }
        let plan = self.store.with_writer_lock(|| {
            let Some(local_head) = self.store.head()? else {
                return Err(validation("artifact store is not initialized"));
            };
            self.validate_configuration(&local_head)?;
            let observed = self.relationship(&local_head, remote_head)?;
            let mut transitions = vec![observed];
            if !publish {
                return self
                    .finish(
                        observed,
                        observed,
                        attempt,
                        Some(local_head),
                        Some(remote_head.to_string()),
                        None,
                        None,
                        &transitions,
                    )
                    .map(|result| Plan::Done(Box::new(result)));
            }
            transitions.push(SyncState::Syncing);
            let candidate = match observed {
                SyncState::Clean => local_head,
                SyncState::Behind => {
                    self.store.ensure_materialization_consistent(&local_head)?;
                    let update = self.store.git(
                        &[
                            "update-ref",
                            &self.store.artifact_ref,
                            remote_head,
                            &local_head,
                        ],
                        &[],
                        None,
                        &[0, 128],
                    )?;
                    if update.status != 0 {
                        transitions.push(SyncState::Ahead);
                        return self
                            .finish(
                                SyncState::Ahead,
                                observed,
                                attempt,
                                self.store.head()?,
                                Some(remote_head.to_string()),
                                Some(
                                    "Local artifact head changed during sync; retry is bounded."
                                        .to_string(),
                                ),
                                None,
                                &transitions,
                            )
                            .map(|result| Plan::Done(Box::new(result)));
                    }
                    remote_head.to_string()
                }
                SyncState::Ahead => {
                    if let Some(blocked) =
                        self.validate_local_commits(Some(remote_head), &local_head)?
                    {
                        transitions.push(SyncState::LocalAheadBlocked);
                        return self
                            .finish(
                                SyncState::LocalAheadBlocked,
                                observed,
                                attempt,
                                Some(local_head),
                                Some(remote_head.to_string()),
                                Some(blocked),
                                None,
                                &transitions,
                            )
                            .map(|result| Plan::Done(Box::new(result)));
                    }
                    local_head
                }
                _ => {
                    self.store.ensure_materialization_consistent(&local_head)?;
                    match self.rebase_unpublished(&local_head, remote_head)? {
                        Replay::Conflict(report) => {
                            transitions.push(SyncState::Conflict);
                            return self
                                .finish(
                                    SyncState::Conflict,
                                    SyncState::Conflict,
                                    attempt,
                                    Some(local_head),
                                    Some(remote_head.to_string()),
                                    Some(
                                        "Review three-way evidence and explicitly choose local, \
                                         remote, delete, or merged bytes for every path."
                                            .to_string(),
                                    ),
                                    Some(report),
                                    &transitions,
                                )
                                .map(|result| Plan::Done(Box::new(result)));
                        }
                        Replay::Blocked(blocked) => {
                            transitions.push(SyncState::LocalAheadBlocked);
                            return self
                                .finish(
                                    SyncState::LocalAheadBlocked,
                                    SyncState::Ahead,
                                    attempt,
                                    Some(local_head),
                                    Some(remote_head.to_string()),
                                    Some(blocked),
                                    None,
                                    &transitions,
                                )
                                .map(|result| Plan::Done(Box::new(result)));
                        }
                        Replay::Commit(commit) => commit,
                    }
                }
            };
            Ok(Plan::Publish {
                candidate,
                observed,
                transitions,
            })
        })?;
        let (candidate, observed, mut transitions) = match plan {
            Plan::Done(result) => return Ok(*result),
            Plan::Publish {
                candidate,
                observed,
                transitions,
            } => (candidate, observed, transitions),
        };

        // The candidate is immutable. Publish it without the writer lock,
        // then re-check canonical authority before reporting the state.
        self.inject("before_push")?;
        let push_destination = match expected_push_url_sha256 {
            Some(expected) => Some(self.validated_push_destination(expected)?),
            None => None,
        };
        let push = self.push(&candidate, push_destination.as_deref(), None)?;
        self.store.with_writer_lock(|| {
            let Some(current_head) = self.store.head()? else {
                return Err(validation("artifact store is not initialized"));
            };
            if let Some((state, recovery)) = push {
                let retry_state = if state == SyncState::Ahead {
                    SyncState::Ahead
                } else {
                    state
                };
                transitions.push(retry_state);
                return self.finish(
                    retry_state,
                    observed,
                    attempt,
                    Some(current_head),
                    Some(remote_head.to_string()),
                    Some(recovery),
                    None,
                    &transitions,
                );
            }
            if current_head != candidate {
                transitions.push(SyncState::Ahead);
                return self.finish(
                    SyncState::Ahead,
                    observed,
                    attempt,
                    Some(current_head),
                    Some(candidate.clone()),
                    Some(
                        "Local artifacts changed during remote publication; \
                         the published revision is durable and retry is bounded."
                            .to_string(),
                    ),
                    None,
                    &transitions,
                );
            }
            self.store.materialize(&candidate, false)?;
            transitions.push(SyncState::Clean);
            self.finish(
                SyncState::Clean,
                observed,
                attempt,
                Some(candidate.clone()),
                Some(candidate.clone()),
                None,
                None,
                &transitions,
            )
        })
    }

    fn rebase_unpublished(&self, local_head: &str, remote_head: &str) -> Result<Replay> {
        let Some(merge_base) = self.merge_base(local_head, remote_head)? else {
            return self
                .aggregate_conflict_report(
                    local_head,
                    remote_head,
                    local_head,
                    Some("unrelated_history"),
                )
                .map(Replay::Conflict);
        };
        if let Some(blocked) = self.validate_local_commits(Some(&merge_base), local_head)? {
            return Ok(Replay::Blocked(blocked));
        }
        let local_commits = self.commits_since(Some(&merge_base), local_head)?;
        let remote_events = self.event_map(remote_head)?;
        let mut replay_base = remote_head.to_string();
        for commit in &local_commits {
            let trailers = self.trailers(commit)?;
            let event_id = trailers.get("Relay-Event-ID").cloned().unwrap_or_default();
            let digest = trailers
                .get("Relay-Event-Digest")
                .cloned()
                .unwrap_or_default();
            if let Some(known) = remote_events.get(&event_id) {
                if *known != digest {
                    return self
                        .aggregate_conflict_report(
                            local_head,
                            remote_head,
                            &merge_base,
                            Some("event_id_collision"),
                        )
                        .map(Replay::Conflict);
                }
                continue;
            }
            let parent = self.store.first_parent(commit)?;
            let parent_entries = tree_of(self.store.tree_entries(parent.as_deref())?);
            let commit_entries = tree_of(self.store.tree_entries(Some(commit))?);
            let replay_entries = tree_of(self.store.tree_entries(Some(&replay_base))?);
            let changes = changed_entries(&parent_entries, &commit_entries);
            let conflicts = path_conflicts(&changes, &replay_entries);
            if !conflicts.is_empty() {
                let mut local_events = Vec::new();
                for item in &local_commits {
                    let trailers = self.trailers(item)?;
                    local_events.push((
                        trailers.get("Relay-Event-ID").cloned().unwrap_or_default(),
                        trailers
                            .get("Relay-Event-Digest")
                            .cloned()
                            .unwrap_or_default(),
                    ));
                }
                return Ok(Replay::Conflict(ConflictReport {
                    project_id: self.store.project_id.clone(),
                    merge_base,
                    local_head: local_head.to_string(),
                    remote_head: remote_head.to_string(),
                    local_events,
                    conflicts,
                }));
            }
            let mut new_entries = replay_entries;
            for (path, (_, new_oid)) in &changes {
                match new_oid {
                    None => {
                        new_entries.remove(path);
                    }
                    Some(_) => {
                        new_entries.insert(path.clone(), commit_entries[path].clone());
                    }
                }
            }
            let tree_id = self.write_tree(&new_entries)?;
            let message = self.message(commit)?;
            replay_base = self
                .store
                .git(
                    &["commit-tree", &tree_id, "-p", &replay_base],
                    &[],
                    Some(message.as_bytes()),
                    &[0],
                )?
                .line();
        }

        let update = self.store.git(
            &[
                "update-ref",
                &self.store.artifact_ref,
                &replay_base,
                local_head,
            ],
            &[],
            None,
            &[0, 128],
        )?;
        if update.status != 0 {
            return Err(concurrent(
                "local artifact CAS failed during unpublished rebase",
            ));
        }
        self.store.materialize(&replay_base, false)?;
        Ok(Replay::Commit(replay_base))
    }

    fn aggregate_conflict_report(
        &self,
        local_head: &str,
        remote_head: &str,
        merge_base: &str,
        kind_override: Option<&str>,
    ) -> Result<ConflictReport> {
        let base = tree_of(self.store.tree_entries(Some(merge_base))?);
        let local = tree_of(self.store.tree_entries(Some(local_head))?);
        let remote = tree_of(self.store.tree_entries(Some(remote_head))?);
        let paths: BTreeSet<&String> = base
            .keys()
            .chain(local.keys())
            .chain(remote.keys())
            .collect();
        let mut conflicts = Vec::new();
        for path in paths {
            let base_oid = oid_of(&base, path);
            let local_oid = oid_of(&local, path);
            let remote_oid = oid_of(&remote, path);
            if local_oid == base_oid || local_oid == remote_oid || remote_oid == base_oid {
                continue;
            }
            conflicts.push(Conflict {
                path: path.clone(),
                kind: kind_override.map_or_else(
                    || conflict_kind(path, &base_oid, &local_oid, &remote_oid).to_string(),
                    str::to_string,
                ),
                base_oid,
                local_oid,
                remote_oid,
                recovery:
                    "Choose the local bytes, remote bytes, deletion, or reviewed merged bytes."
                        .to_string(),
            });
        }
        if conflicts.is_empty() {
            conflicts.push(Conflict {
                path: ".orchestrator/config.toml".to_string(),
                kind: kind_override.unwrap_or("history_conflict").to_string(),
                base_oid: None,
                local_oid: None,
                remote_oid: None,
                recovery: "Inspect the unrelated artifact histories and select an explicit \
                           identity-preserving recovery."
                    .to_string(),
            });
        }
        let mut local_events = Vec::new();
        for commit in self.commits_since(Some(merge_base), local_head)? {
            let trailers = self.trailers(&commit)?;
            if let (Some(event_id), Some(digest)) = (
                trailers.get("Relay-Event-ID"),
                trailers.get("Relay-Event-Digest"),
            ) {
                local_events.push((event_id.clone(), digest.clone()));
            }
        }
        Ok(ConflictReport {
            project_id: self.store.project_id.clone(),
            merge_base: merge_base.to_string(),
            local_head: local_head.to_string(),
            remote_head: remote_head.to_string(),
            local_events,
            conflicts,
        })
    }

    fn resolved_entries(
        &self,
        report: &ConflictReport,
        decisions: &BTreeMap<String, Decision>,
    ) -> Result<Tree> {
        let base = tree_of(self.store.tree_entries(Some(&report.merge_base))?);
        let local = tree_of(self.store.tree_entries(Some(&report.local_head))?);
        let remote = tree_of(self.store.tree_entries(Some(&report.remote_head))?);
        let mut result = remote.clone();
        let conflict_paths: BTreeSet<&String> =
            report.conflicts.iter().map(|item| &item.path).collect();
        let paths: BTreeSet<&String> = base
            .keys()
            .chain(local.keys())
            .chain(remote.keys())
            .collect();
        for path in paths {
            let base_oid = oid_of(&base, path);
            let local_oid = oid_of(&local, path);
            let remote_oid = oid_of(&remote, path);
            if local_oid == base_oid || local_oid == remote_oid {
                continue;
            }
            if remote_oid == base_oid {
                match local.get(path) {
                    Some(entry) => {
                        result.insert(path.clone(), entry.clone());
                    }
                    None => {
                        result.remove(path);
                    }
                }
                continue;
            }
            if !conflict_paths.contains(path) {
                continue;
            }
            match &decisions[path] {
                Decision::Keyword(word) if word == "local" => match local.get(path) {
                    Some(entry) => {
                        result.insert(path.clone(), entry.clone());
                    }
                    None => {
                        result.remove(path);
                    }
                },
                Decision::Keyword(word) if word == "remote" => {}
                Decision::Keyword(word) if word == "delete" => {
                    result.remove(path);
                }
                Decision::Bytes(content) => {
                    validate_allowlisted_path(path)?;
                    self.store.validate_content_for_path(path, content)?;
                    let blob = self
                        .store
                        .git(&["hash-object", "-w", "--stdin"], &[], Some(content), &[0])?
                        .line();
                    let Some(template) = local
                        .get(path)
                        .or_else(|| remote.get(path))
                        .or_else(|| base.get(path))
                    else {
                        return Err(validation(format!(
                            "cannot infer artifact mode for merged path {path}"
                        )));
                    };
                    result.insert(
                        path.clone(),
                        TreeEntry {
                            mode: "100644".to_string(),
                            kind: "blob".to_string(),
                            oid: blob,
                            path: template.path.clone(),
                        },
                    );
                }
                Decision::Keyword(word) => {
                    return Err(validation(format!(
                        "invalid resolution for {path}: {}",
                        pystr::repr(word)
                    )));
                }
            }
        }
        Ok(result)
    }

    fn write_tree(&self, entries: &Tree) -> Result<String> {
        let directory = make_temporary_directory("relay-sync-index-")?;
        let result = (|| {
            let index = directory.join("index");
            let index = index.to_string_lossy().into_owned();
            let environment = [("GIT_INDEX_FILE", index.as_str())];
            self.store
                .git(&["read-tree", "--empty"], &environment, None, &[0])?;
            for (path, entry) in entries {
                validate_allowlisted_path(path)?;
                if entry.mode != "100644" || entry.kind != "blob" {
                    return Err(validation(format!(
                        "resolution contains unsupported entry {path}"
                    )));
                }
                self.store.git(
                    &[
                        "update-index",
                        "--add",
                        "--cacheinfo",
                        "100644",
                        &entry.oid,
                        path,
                    ],
                    &environment,
                    None,
                    &[0],
                )?;
            }
            let tree_id = self
                .store
                .git(&["write-tree"], &environment, None, &[0])?
                .line();
            self.store
                .validate_note_catalog_entries(&self.store.tree_entries(Some(&tree_id))?)?;
            Ok(tree_id)
        })();
        let _ = fs::remove_dir_all(&directory);
        result
    }

    fn validate_local_commits(&self, base: Option<&str>, head: &str) -> Result<Option<String>> {
        for commit in self.commits_since(base, head)? {
            let trailers = self.trailers(&commit)?;
            if trailers.get("Relay-Project-ID").map(String::as_str)
                != Some(self.store.project_id.as_str())
            {
                return Ok(Some(format!(
                    "local artifact commit {commit} is not owned by project {}; \
                     inspect it before any publication",
                    self.store.project_id
                )));
            }
            for key in [
                "Relay-Event-ID",
                "Relay-Event-Digest",
                "Relay-Device-ID",
                "Relay-Actor-Type",
            ] {
                if trailers.get(key).is_none_or(String::is_empty) {
                    return Ok(Some(format!(
                        "local artifact commit {commit} lacks required trailer {key}"
                    )));
                }
            }
        }
        Ok(None)
    }

    fn commits_since(&self, base: Option<&str>, head: &str) -> Result<Vec<String>> {
        let revision = match base.filter(|base| !base.is_empty()) {
            Some(base) => format!("{base}..{head}"),
            None => head.to_string(),
        };
        let output = self
            .store
            .git(&["rev-list", "--reverse", &revision], &[], None, &[0])?
            .text();
        Ok(pystr::splitlines(&output)
            .into_iter()
            .map(str::to_string)
            .collect())
    }

    fn message(&self, commit: &str) -> Result<String> {
        Ok(self
            .store
            .git(&["show", "-s", "--format=%B", commit], &[], None, &[0])?
            .text())
    }

    fn trailers(&self, commit: &str) -> Result<std::collections::HashMap<String, String>> {
        Ok(parse_trailers(&self.message(commit)?))
    }

    fn event_map(&self, head: &str) -> Result<BTreeMap<String, String>> {
        let mut result = BTreeMap::new();
        let listing = self.store.git(&["rev-list", head], &[], None, &[0])?.text();
        for commit in pystr::splitlines(&listing) {
            let trailers = self.trailers(commit)?;
            if let (Some(event_id), Some(digest)) = (
                trailers
                    .get("Relay-Event-ID")
                    .filter(|value| !value.is_empty()),
                trailers
                    .get("Relay-Event-Digest")
                    .filter(|value| !value.is_empty()),
            ) {
                result.insert(event_id.clone(), digest.clone());
            }
            let message = self.message(commit)?;
            for line in pystr::splitlines(&message) {
                if let Some(rest) = line.strip_prefix("Relay-Resolved-Event: ") {
                    let parts: Vec<&str> = rest.splitn(2, ' ').collect();
                    if parts.len() == 2 {
                        result.insert(parts[0].to_string(), parts[1].to_string());
                    }
                }
            }
        }
        Ok(result)
    }

    fn relationship(&self, local_head: &str, remote_head: &str) -> Result<SyncState> {
        if local_head == remote_head {
            return Ok(SyncState::Clean);
        }
        if self.is_ancestor(remote_head, local_head)? {
            return Ok(SyncState::Ahead);
        }
        if self.is_ancestor(local_head, remote_head)? {
            return Ok(SyncState::Behind);
        }
        Ok(SyncState::Conflict)
    }

    fn is_ancestor(&self, ancestor: &str, descendant: &str) -> Result<bool> {
        Ok(self
            .store
            .git(
                &["merge-base", "--is-ancestor", ancestor, descendant],
                &[],
                None,
                &[0, 1, 128],
            )?
            .status
            == 0)
    }

    fn merge_base(&self, first: &str, second: &str) -> Result<Option<String>> {
        let result = self
            .store
            .git(&["merge-base", first, second], &[], None, &[0, 1, 128])?;
        Ok((result.status == 0).then(|| result.line()))
    }

    fn validate_configuration(&self, head: &str) -> Result<()> {
        self.store.validate_artifact_head(head)?;
        let content = self
            .store
            .git(
                &["show", &format!("{head}:.orchestrator/config.toml")],
                &[],
                None,
                &[0],
            )?
            .stdout;
        let document = toml::loads_bytes(&content)?;
        let remote_sync = document.get("remote_sync");
        if remote_sync.and_then(toml::Value::as_str) != Some(self.mode.value()) {
            return Err(validation(format!(
                "artifact config mode is {}, not {}",
                toml_repr(remote_sync),
                pystr::repr(self.mode.value())
            )));
        }
        if self.mode == SyncMode::Enabled
            && document.get("remote_name").and_then(toml::Value::as_str)
                != self.remote_name.as_deref()
        {
            return Err(validation(
                "sync remote must be selected explicitly in artifact configuration",
            ));
        }
        if let Some(name) = self.remote_name.as_deref().filter(|name| !name.is_empty()) {
            let result = self
                .store
                .git(&["remote", "get-url", name], &[], None, &[0, 2, 128])?;
            if result.status != 0 || result.line().is_empty() {
                return Err(validation(format!(
                    "configured existing remote {} is unavailable; Relay will not create it",
                    pystr::repr(name)
                )));
            }
        }
        Ok(())
    }

    /// `_remote_snapshot`: fetch exactly the artifact ref into a throwaway
    /// bare quarantine, verify it, import it under a scratch ref, run
    /// `work`, then remove the scratch ref and the quarantine.
    fn with_remote_snapshot<T>(
        &self,
        expected_url_sha256: Option<&str>,
        work: impl FnOnce(&RemoteSnapshot) -> Result<T>,
    ) -> Result<T> {
        let remote_name = self.remote_name.clone().unwrap_or_default();
        let remote_url = match expected_url_sha256 {
            None => {
                let result = self.store.git(
                    &["remote", "get-url", &remote_name],
                    &[],
                    None,
                    &[0, 2, 128],
                )?;
                if result.status != 0 {
                    return work(&RemoteSnapshot::error(
                        None,
                        None,
                        SyncState::Failed,
                        format!(
                            "Configured remote {} no longer exists; select another existing remote or Local only.",
                            pystr::repr(&remote_name)
                        ),
                    ));
                }
                result.line()
            }
            Some(expected) => self.validated_fetch_destination(expected)?,
        };
        let temporary = make_temporary_directory("relay-artifact-quarantine-")?;
        let result = self.with_quarantine(&temporary, &remote_url, work);
        let _ = fs::remove_dir_all(&temporary);
        result
    }

    fn with_quarantine<T>(
        &self,
        temporary: &Path,
        remote_url: &str,
        work: impl FnOnce(&RemoteSnapshot) -> Result<T>,
    ) -> Result<T> {
        let quarantine = temporary.join("remote.git");
        let initialized = Command::new("git")
            .args(["init", "--bare", "--quiet"])
            .arg(&quarantine)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .map_err(|error| Error::new(ErrorKind::Io, format!("git could not start: {error}")))?;
        if !initialized.status.success() {
            return Err(Error::new(
                ErrorKind::Runtime,
                format!(
                    "Command '['git', 'init', '--bare', '--quiet', {}]' returned non-zero exit status {}.",
                    pystr::repr(&quarantine.to_string_lossy()),
                    initialized.status.code().unwrap_or(-1)
                ),
            ));
        }
        let refspec = format!("{0}:{0}", self.store.artifact_ref);
        let fetch = quarantine_process(
            &quarantine,
            &[
                "fetch",
                "--no-tags",
                "--no-write-fetch-head",
                "--no-recurse-submodules",
                remote_url,
                &refspec,
            ],
        )?;
        if fetch.status != 0 {
            let (state, recovery) =
                Self::classify_git_failure(&String::from_utf8_lossy(&fetch.stderr), "fetch");
            return work(&RemoteSnapshot::error(
                None,
                Some(quarantine),
                state,
                recovery,
            ));
        }
        let remote_head =
            self.quarantine_git(&quarantine, &["rev-parse", &self.store.artifact_ref])?;
        if let Err(error) = self.validate_quarantine(&quarantine, &remote_head) {
            let recovery = if error.kind == ErrorKind::Identity {
                error.message
            } else if error.kind.is_validation() {
                format!("Remote artifact ref failed verification: {error}")
            } else {
                return Err(error);
            };
            return work(&RemoteSnapshot::error(
                Some(remote_head),
                Some(quarantine),
                SyncState::ForeignRef,
                recovery,
            ));
        }
        let scratch_ref = format!(
            "refs/relay-runner/sync/{}/{}",
            self.store.project_id,
            uuid_hex()
        );
        let imported = self.store.git(
            &[
                "fetch",
                "--no-tags",
                "--no-write-fetch-head",
                "--no-recurse-submodules",
                &quarantine.to_string_lossy(),
                &format!("{}:{scratch_ref}", self.store.artifact_ref),
            ],
            &[],
            None,
            &[0, 128],
        )?;
        if imported.status != 0 {
            return work(&RemoteSnapshot::error(
                None,
                Some(quarantine),
                SyncState::Failed,
                "Verified artifact objects could not be imported into the local repository.",
            ));
        }
        let result = (|| {
            let imported_head = self
                .store
                .git(&["rev-parse", &scratch_ref], &[], None, &[0])?
                .line();
            if imported_head != remote_head {
                return work(&RemoteSnapshot::error(
                    None,
                    Some(quarantine.clone()),
                    SyncState::Ahead,
                    "Remote artifact ref changed during quarantine; retry is bounded.",
                ));
            }
            work(&RemoteSnapshot {
                head: Some(remote_head.clone()),
                quarantine: Some(quarantine.clone()),
                error_state: None,
                recovery: None,
            })
        })();
        let cleanup = self
            .store
            .git(&["update-ref", "-d", &scratch_ref], &[], None, &[0, 128]);
        match (result, cleanup) {
            (Ok(value), Ok(_)) => Ok(value),
            (Ok(_), Err(error)) => Err(error),
            (Err(error), _) => Err(error),
        }
    }

    /// `_validate_quarantine`: the fetched history must be orphan-rooted,
    /// linear, and hold only valid artifact files and catalogs; only commits
    /// after the last fully verified head are walked again.
    fn validate_quarantine(&self, repository: &Path, head: &str) -> Result<()> {
        self.inject("before_remote_history_validation")?;
        let parents = |revision: &str| -> Result<Vec<Vec<String>>> {
            let listing = self.quarantine_git(
                repository,
                &["rev-list", "--reverse", "--parents", revision],
            )?;
            Ok(pystr::splitlines(&listing)
                .into_iter()
                .map(|line| {
                    line.split_whitespace()
                        .map(str::to_string)
                        .collect::<Vec<_>>()
                })
                .collect())
        };
        let history: Vec<Vec<String>> = match self.verified_remote_head(repository, head) {
            None => {
                let history = parents(head)?;
                if history.is_empty() || history[0].len() != 1 {
                    return Err(validation("remote artifact ref is not orphan-rooted"));
                }
                let mut previous = history[0][0].clone();
                for line in &history[1..] {
                    if line.len() != 2 || line[1] != previous {
                        return Err(validation("remote artifact history is not linear"));
                    }
                    previous = line[0].clone();
                }
                history
            }
            Some(verified) => {
                // Object IDs bind everything up to the verified head, so
                // only commits after it can differ (RR-440).
                let mut history = Vec::new();
                if verified != head {
                    history = parents(&format!("{verified}..{head}"))?;
                    let mut previous = verified.clone();
                    for line in &history {
                        if line.len() != 2 || line[1] != previous {
                            return Err(validation("remote artifact history is not linear"));
                        }
                        previous = line[0].clone();
                    }
                    history.insert(0, vec![verified]);
                }
                history
            }
        };
        // Reuse only unchanged path/blob pairs from the preceding tree.
        let mut previous_contents: BTreeMap<(String, String), Vec<u8>> = BTreeMap::new();
        for line in &history {
            let output = self.quarantine_git_bytes(
                repository,
                &["ls-tree", "-r", "-z", "--full-tree", &line[0]],
            )?;
            let mut note_files: BTreeMap<String, Vec<u8>> = BTreeMap::new();
            let mut current_contents: BTreeMap<(String, String), Vec<u8>> = BTreeMap::new();
            for record in output.split(|byte| *byte == 0) {
                if record.is_empty() {
                    continue;
                }
                let tab = record
                    .iter()
                    .position(|byte| *byte == b'\t')
                    .ok_or_else(|| {
                        Error::value("not enough values to unpack (expected 2, got 1)")
                    })?;
                let metadata = String::from_utf8_lossy(&record[..tab]).into_owned();
                let mut fields = metadata.splitn(3, ' ');
                let (Some(mode), Some(kind), Some(oid)) =
                    (fields.next(), fields.next(), fields.next())
                else {
                    return Err(Error::value("not enough values to unpack (expected 3)"));
                };
                let path = pystr::decode_utf8(&record[tab + 1..])?.to_string();
                validate_allowlisted_path(&path)?;
                if mode != "100644" || kind != "blob" {
                    return Err(validation(format!(
                        "remote artifact contains unsupported {mode} {kind}: {path}"
                    )));
                }
                let key = (path.clone(), oid.to_string());
                let content = match previous_contents.remove(&key) {
                    Some(content) => content,
                    None => {
                        let content =
                            self.quarantine_git_bytes(repository, &["cat-file", "blob", oid])?;
                        self.store.validate_content_for_path(&path, &content)?;
                        content
                    }
                };
                if path == ".orchestrator/note-index.jsonl"
                    || path.starts_with(".orchestrator/notes/")
                {
                    note_files.insert(path.clone(), content.clone());
                }
                current_contents.insert(key, content);
            }
            self.store.validate_note_catalog_files(&note_files)?;
            previous_contents = current_contents;
        }
        let config = self
            .quarantine_git_bytes(
                repository,
                &["show", &format!("{head}:.orchestrator/config.toml")],
            )
            .map_err(|error| {
                if error.kind.is_store_error() {
                    validation("remote artifact config is missing")
                } else {
                    error
                }
            })?;
        let document = toml::loads_bytes(&config)?;
        let project = document.get("project_id");
        if project.and_then(toml::Value::as_str) != Some(self.store.project_id.as_str()) {
            return Err(Error::new(
                ErrorKind::Identity,
                format!(
                    "remote artifact ref belongs to project {}",
                    toml_repr(project)
                ),
            ));
        }
        if document.get("artifact_ref").and_then(toml::Value::as_str)
            != Some(self.store.artifact_ref.as_str())
        {
            return Err(validation("remote artifact config names another ref"));
        }
        if document.get("remote_sync").and_then(toml::Value::as_str)
            != Some(SyncMode::Enabled.value())
        {
            return Err(validation(
                "remote artifact config is not enabled for synchronization",
            ));
        }
        if document.get("remote_name").and_then(toml::Value::as_str) != self.remote_name.as_deref()
        {
            return Err(validation(
                "remote artifact config names another selected remote",
            ));
        }
        self.record_verified_remote_head(head);
        Ok(())
    }

    /// `_remote_history_verification_path`.
    pub fn remote_history_verification_path(&self) -> PathBuf {
        self.store
            .project_state
            .join("remote-history-verification.json")
    }

    /// The last fully verified remote head when `head` descends from it.
    fn verified_remote_head(&self, repository: &Path, head: &str) -> Option<String> {
        let bytes = fs::read(self.remote_history_verification_path()).ok()?;
        let text = std::str::from_utf8(&bytes).ok()?;
        let Some(Value::Dict(cache)) = json::parse(&pystr::universal_newlines(text)) else {
            return None;
        };
        if !cache
            .get("version")
            .is_some_and(|version| json::py_eq(version, &Value::Int(1)))
            || cache.get("project_id").and_then(Value::as_str)
                != Some(self.store.project_id.as_str())
        {
            return None;
        }
        let commit_id = cache.get("commit_id").and_then(Value::as_str)?;
        if !is_oid(commit_id) {
            return None;
        }
        if commit_id == head || self.quarantine_is_ancestor(repository, commit_id, head) {
            return Some(commit_id.to_string());
        }
        None
    }

    fn record_verified_remote_head(&self, head: &str) {
        let mut payload = Dict::new();
        payload.insert("version", 1i64);
        payload.insert("project_id", self.store.project_id.as_str());
        payload.insert("commit_id", head);
        // The next sync repeats the full walk when this fails.
        let _ = self
            .store
            .write_json_atomic(&self.remote_history_verification_path(), &payload);
    }

    fn verified_prepared_result(
        &self,
        remote: &RemoteSnapshot,
        candidate_head: &str,
        proofs: &[RemoteProof],
        attempts: i64,
    ) -> Result<SyncResult> {
        let (head, quarantine) = snapshot_parts(remote);
        if let Err(error) = self.verify_remote_proofs(quarantine, head, proofs) {
            if !error.kind.is_validation() {
                return Err(error);
            }
            return self.finish(
                SyncState::Failed,
                SyncState::Failed,
                attempts,
                Some(candidate_head.to_string()),
                Some(head.to_string()),
                Some(format!(
                    "Published artifact integrity verification failed: {error}"
                )),
                None,
                &[SyncState::Syncing, SyncState::Failed],
            );
        }
        self.finish(
            SyncState::Clean,
            SyncState::Ahead,
            attempts,
            Some(candidate_head.to_string()),
            Some(head.to_string()),
            None,
            None,
            &[SyncState::Ahead, SyncState::Syncing, SyncState::Clean],
        )
    }

    fn verify_remote_proofs(
        &self,
        repository: &Path,
        remote_head: &str,
        proofs: &[RemoteProof],
    ) -> Result<()> {
        for proof in proofs {
            if !is_oid(&proof.source_commit) {
                return Err(validation("archive proof has an invalid source commit"));
            }
            if !is_oid(&proof.blob_id) {
                return Err(validation("archive proof has an invalid blob ID"));
            }
            if !is_sha256(&proof.sha256) {
                return Err(validation("archive proof has an invalid SHA-256 digest"));
            }
            if !self.quarantine_is_ancestor(repository, &proof.source_commit, remote_head) {
                return Err(validation(format!(
                    "archive source commit is unreachable for {}",
                    proof.path
                )));
            }
            let unavailable = |error: Error| {
                if error.kind.is_store_error() {
                    validation(format!(
                        "published archive object is unavailable for {}",
                        proof.path
                    ))
                } else {
                    error
                }
            };
            let actual_blob = self
                .quarantine_git(
                    repository,
                    &[
                        "rev-parse",
                        &format!("{}:{}", proof.source_commit, proof.path),
                    ],
                )
                .map_err(unavailable)?;
            let content = self
                .quarantine_git_bytes(repository, &["cat-file", "blob", &proof.blob_id])
                .map_err(unavailable)?;
            if actual_blob != proof.blob_id {
                return Err(validation(format!(
                    "published archive blob identity changed for {}",
                    proof.path
                )));
            }
            if hex_digest(&content) != proof.sha256 {
                return Err(validation(format!(
                    "published archive digest changed for {}",
                    proof.path
                )));
            }
        }
        Ok(())
    }

    fn quarantine_is_ancestor(&self, repository: &Path, ancestor: &str, descendant: &str) -> bool {
        quarantine_process(
            repository,
            &["merge-base", "--is-ancestor", ancestor, descendant],
        )
        .is_ok_and(|output| output.status == 0)
    }

    fn validated_push_destination(&self, expected_sha256: &str) -> Result<String> {
        if !is_sha256(expected_sha256) {
            return Err(validation("confirmed push destination digest is invalid"));
        }
        let remote_name = self.remote_name.clone().unwrap_or_default();
        let result = self.store.git(
            &["remote", "get-url", "--push", "--all", &remote_name],
            &[],
            None,
            &[0, 2, 128],
        )?;
        let text = result.text();
        let destinations = pystr::splitlines(&text);
        if result.status != 0 || destinations.len() != 1 || destinations[0].is_empty() {
            return Err(validation(
                "exactly one confirmed push destination must remain configured",
            ));
        }
        let destination = destinations[0].to_string();
        if hex_digest(destination.as_bytes()) != expected_sha256 {
            return Err(validation(
                "the push destination changed after exposure confirmation",
            ));
        }
        Ok(destination)
    }

    fn validated_fetch_destination(&self, expected_sha256: &str) -> Result<String> {
        if !is_sha256(expected_sha256) {
            return Err(validation("confirmed fetch destination digest is invalid"));
        }
        let remote_name = self.remote_name.clone().unwrap_or_default();
        let result = self.store.git(
            &["remote", "get-url", &remote_name],
            &[],
            None,
            &[0, 2, 128],
        )?;
        let destination = result.line();
        if result.status != 0 || destination.is_empty() {
            return Err(validation(
                "the confirmed fetch destination is no longer configured",
            ));
        }
        if hex_digest(destination.as_bytes()) != expected_sha256 {
            return Err(validation(
                "the fetch destination changed after exposure confirmation",
            ));
        }
        Ok(destination)
    }

    /// `_push`: a normal push (a lease on the exact base when given, never
    /// a force); `None` on success, else the classified failure.
    fn push(
        &self,
        local_head: &str,
        destination: Option<&str>,
        expected_remote_head: Option<&str>,
    ) -> Result<Option<(SyncState, String)>> {
        let remote_name = self.remote_name.clone().unwrap_or_default();
        let lease = expected_remote_head
            .map(|head| format!("--force-with-lease={}:{head}", self.store.artifact_ref));
        let refspec = format!("{local_head}:{}", self.store.artifact_ref);
        let mut arguments = vec!["push", "--porcelain"];
        if let Some(lease) = &lease {
            arguments.push(lease);
        }
        arguments.push(destination.unwrap_or(&remote_name));
        arguments.push(&refspec);
        let push = self.store.git(&arguments, &[], None, &[0, 1, 128])?;
        if push.status == 0 {
            return Ok(None);
        }
        let message = format!("{}\n{}", String::from_utf8_lossy(&push.stderr), push.text());
        Ok(Some(Self::classify_git_failure(&message, "push")))
    }

    /// `ArtifactSyncEngine.classify_git_failure` (a static method).
    pub fn classify_git_failure(message: &str, operation: &str) -> (SyncState, String) {
        let lower = message.to_lowercase();
        let has = |markers: &[&str]| markers.iter().any(|marker| lower.contains(marker));
        let (state, recovery) = if has(&["couldn't find remote ref", "remote ref does not exist"]) {
            (
                SyncState::MissingRemoteRef,
                "The configured artifact ref is missing. Confirm a first normal push or choose Local only.",
            )
        } else if has(&[
            "authentication failed",
            "could not read username",
            "permission denied (publickey)",
            "terminal prompts disabled",
        ]) {
            (
                SyncState::RetryableAuth,
                "Authenticate the configured Git remote, then retry; local artifact commits remain ahead.",
            )
        } else if has(&[
            "could not resolve host",
            "failed to connect",
            "network is unreachable",
            "operation timed out",
            "connection timed out",
        ]) {
            (
                SyncState::RetryableOffline,
                "Reconnect to the configured remote and retry; local artifact commits remain available.",
            )
        } else if has(&[
            "protected branch",
            "protected ref",
            "pre-receive hook declined",
            "deny updating a hidden ref",
            "hook declined",
        ]) {
            (
                SyncState::ProtectedRef,
                "The remote protects the artifact ref. Change its policy explicitly or use Local only; Relay will not force push.",
            )
        } else if operation == "push"
            && has(&["non-fast-forward", "fetch first", "stale info", "rejected"])
        {
            (
                SyncState::Ahead,
                "The remote advanced during push; refetch and retry without force.",
            )
        } else {
            (
                SyncState::Failed,
                "Git artifact synchronization failed without a safe automatic recovery; inspect the configured remote.",
            )
        };
        (state, recovery.to_string())
    }

    fn remote_error_result(
        &self,
        remote: &RemoteSnapshot,
        local_head: Option<String>,
        attempts: i64,
    ) -> Result<SyncResult> {
        let state = remote.error_state.unwrap_or(SyncState::Failed);
        let observed = if local_head.as_deref().is_some_and(|head| !head.is_empty()) {
            SyncState::Ahead
        } else {
            state
        };
        self.finish(
            state,
            observed,
            attempts,
            local_head,
            remote.head.clone(),
            remote.recovery.clone(),
            None,
            &[SyncState::Syncing, state],
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn finish(
        &self,
        state: SyncState,
        observed_state: SyncState,
        attempts: i64,
        local_head: Option<String>,
        remote_head: Option<String>,
        recovery: Option<String>,
        conflict_report: Option<ConflictReport>,
        transitions: &[SyncState],
    ) -> Result<SyncResult> {
        let result = SyncResult {
            state,
            observed_state,
            transitions: transitions.to_vec(),
            attempts,
            local_head,
            remote_head,
            recovery,
            conflict_report,
        };
        self.persist_state(&result)?;
        Ok(result)
    }

    fn persist_state(&self, result: &SyncResult) -> Result<()> {
        let mut payload = Dict::new();
        payload.insert("version", 1i64);
        payload.insert("project_id", self.store.project_id.as_str());
        payload.insert("artifact_ref", self.store.artifact_ref.as_str());
        payload.insert("mode", self.mode.value());
        payload.insert("remote_name", optional(&self.remote_name));
        payload.insert("state", result.state.value());
        payload.insert("observed_state", result.observed_state.value());
        payload.insert(
            "transitions",
            Value::List(
                result
                    .transitions
                    .iter()
                    .map(|state| Value::Str(state.value().to_string()))
                    .collect(),
            ),
        );
        payload.insert("attempts", result.attempts);
        payload.insert("local_head", optional(&result.local_head));
        payload.insert("remote_head", optional(&result.remote_head));
        payload.insert("recovery", optional(&result.recovery));
        payload.insert(
            "conflicts",
            Value::List(
                result
                    .conflict_report
                    .iter()
                    .flat_map(|report| report.conflicts.iter())
                    .map(|conflict| Value::Dict(conflict.as_dict()))
                    .collect(),
            ),
        );
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_secs() as i64);
        payload.insert("updated_at", now);
        self.store.write_json_atomic(&self.state_path, &payload)
    }

    fn resolution_message(
        &self,
        report: &ConflictReport,
        event_id: &str,
        digest: &str,
        device_id: &str,
        actor_type: &str,
        provider: Option<&str>,
    ) -> String {
        let mut lines = vec![
            "Resolve Relay artifact conflict".to_string(),
            String::new(),
            format!("Relay-Project-ID: {}", self.store.project_id),
            format!("Relay-Event-ID: {event_id}"),
            format!("Relay-Event-Digest: {digest}"),
            format!("Relay-Device-ID: {device_id}"),
            format!("Relay-Actor-Type: {actor_type}"),
        ];
        if let Some(provider) = provider.filter(|provider| !provider.is_empty()) {
            lines.push(format!("Relay-Provider: {provider}"));
        }
        for (event, event_digest) in &report.local_events {
            lines.push(format!("Relay-Resolved-Event: {event} {event_digest}"));
        }
        lines.join("\n") + "\n"
    }

    fn inject(&self, stage: &str) -> Result<()> {
        match &self.failure_injector {
            Some(injector) => injector(stage),
            None => Ok(()),
        }
    }

    fn quarantine_git(&self, repository: &Path, arguments: &[&str]) -> Result<String> {
        let bytes = self.quarantine_git_bytes(repository, arguments)?;
        Ok(pystr::strip(&String::from_utf8_lossy(&bytes)).to_string())
    }

    fn quarantine_git_bytes(&self, repository: &Path, arguments: &[&str]) -> Result<Vec<u8>> {
        let output = quarantine_process(repository, arguments)?;
        if output.status != 0 {
            return Err(Error::new(
                ErrorKind::Store,
                format!(
                    "quarantine git {} failed: {}",
                    arguments.join(" "),
                    pystr::strip(&String::from_utf8_lossy(&output.stderr))
                ),
            ));
        }
        Ok(output.stdout)
    }
}

/// The head and quarantine of a snapshot without an error.
fn snapshot_parts(remote: &RemoteSnapshot) -> (&str, &Path) {
    (
        remote.head.as_deref().unwrap_or_default(),
        remote.quarantine.as_deref().unwrap_or(Path::new("")),
    )
}

fn is_remote_name(name: &str) -> bool {
    (1..=128).contains(&name.len())
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

/// Whether Python's `except (ArtifactStoreError, ValueError)` catches it.
fn is_store_or_value_error(kind: ErrorKind) -> bool {
    kind.is_store_error()
        || matches!(
            kind,
            ErrorKind::Value
                | ErrorKind::TicketParse
                | ErrorKind::TomlDecode
                | ErrorKind::NoteContract
                | ErrorKind::CatalogSemantic
        )
}

fn uuid_hex() -> String {
    let mut bytes = [0u8; 16];
    if File::open("/dev/urandom")
        .and_then(|mut source| source.read_exact(&mut bytes))
        .is_err()
    {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        bytes = (nanos ^ (u128::from(std::process::id()) << 64)).to_le_bytes();
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `_changed_entries`: `{path: (old_oid, new_oid)}` for every changed path.
fn changed_entries(old: &Tree, new: &Tree) -> BTreeMap<String, (Option<String>, Option<String>)> {
    let paths: BTreeSet<&String> = old.keys().chain(new.keys()).collect();
    paths
        .into_iter()
        .filter_map(|path| {
            let old_oid = oid_of(old, path);
            let new_oid = oid_of(new, path);
            (old_oid != new_oid).then(|| (path.clone(), (old_oid, new_oid)))
        })
        .collect()
}

/// `_path_conflicts`.
fn path_conflicts(
    changes: &BTreeMap<String, (Option<String>, Option<String>)>,
    replay_entries: &Tree,
) -> Vec<Conflict> {
    changes
        .iter()
        .filter_map(|(path, (base_oid, local_oid))| {
            let remote_oid = oid_of(replay_entries, path);
            if remote_oid == *base_oid || remote_oid == *local_oid {
                return None;
            }
            Some(Conflict {
                path: path.clone(),
                kind: conflict_kind(path, base_oid, local_oid, &remote_oid).to_string(),
                base_oid: base_oid.clone(),
                local_oid: local_oid.clone(),
                remote_oid,
                recovery: "Review the base, local, and remote blob IDs before choosing a result."
                    .to_string(),
            })
        })
        .collect()
}

/// `_conflict_kind`.
fn conflict_kind(
    path: &str,
    base_oid: &Option<String>,
    local_oid: &Option<String>,
    remote_oid: &Option<String>,
) -> &'static str {
    if local_oid.is_none() || remote_oid.is_none() {
        return "delete_edit";
    }
    if path == ".orchestrator/config.toml" {
        return "config_collision";
    }
    if path.starts_with(".orchestrator/attachments/") {
        return "attachment_collision";
    }
    if path.starts_with(".orchestrator/notes/") {
        return if base_oid.is_none() {
            "note_display_id_collision"
        } else {
            "same_note"
        };
    }
    if path.ends_with(".md") {
        return if base_oid.is_none() {
            "display_id_collision"
        } else {
            "same_ticket"
        };
    }
    "artifact_path_collision"
}

/// `_resolution_digest`: SHA-256 of the sorted, compact JSON of the heads
/// and decisions, merged bytes reduced to their SHA-256 and length.
fn resolution_digest(report: &ConflictReport, decisions: &BTreeMap<String, Decision>) -> String {
    let mut serialized = Dict::new();
    for (path, decision) in decisions {
        let value = match decision {
            Decision::Bytes(content) => {
                let mut summary = Dict::new();
                summary.insert("sha256", hex_digest(content));
                summary.insert("bytes", content.len() as i64);
                Value::Dict(summary)
            }
            Decision::Keyword(word) => Value::Str(word.clone()),
        };
        serialized.insert(path, value);
    }
    let mut payload = Dict::new();
    payload.insert("merge_base", report.merge_base.as_str());
    payload.insert("local_head", report.local_head.as_str());
    payload.insert("remote_head", report.remote_head.as_str());
    payload.insert("decisions", serialized);
    hex_digest(json::dumps_compact_sorted(&Value::Dict(payload)).as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_git_failures_like_python() {
        let cases = [
            (
                "Could not resolve host github.com",
                "fetch",
                SyncState::RetryableOffline,
            ),
            ("Authentication failed", "fetch", SyncState::RetryableAuth),
            (
                "protected branch hook declined",
                "fetch",
                SyncState::ProtectedRef,
            ),
            ("rejected non-fast-forward", "push", SyncState::Ahead),
            ("rejected non-fast-forward", "fetch", SyncState::Failed),
            (
                "couldn't find remote ref",
                "fetch",
                SyncState::MissingRemoteRef,
            ),
            ("something else", "push", SyncState::Failed),
        ];
        for (message, operation, expected) in cases {
            let (state, recovery) = ArtifactSyncEngine::classify_git_failure(message, operation);
            assert_eq!(state, expected, "{message}");
            assert!(!recovery.is_empty());
        }
    }

    #[test]
    fn conflict_kinds() {
        let some = Some("a".to_string());
        assert_eq!(
            conflict_kind(".orchestrator/RR-1.md", &None, &some, &some),
            "display_id_collision"
        );
        assert_eq!(
            conflict_kind(".orchestrator/RR-1.md", &some, &some, &some),
            "same_ticket"
        );
        assert_eq!(
            conflict_kind(".orchestrator/RR-1.md", &some, &None, &some),
            "delete_edit"
        );
        assert_eq!(
            conflict_kind(".orchestrator/config.toml", &some, &some, &some),
            "config_collision"
        );
        assert_eq!(
            conflict_kind(".orchestrator/attachments/RR-1/a.png", &None, &some, &some),
            "attachment_collision"
        );
        assert_eq!(
            conflict_kind(".orchestrator/notes/RR-N1.md", &None, &some, &some),
            "note_display_id_collision"
        );
    }

    #[test]
    fn random_unit_is_in_range() {
        for _ in 0..100 {
            let value = random_unit();
            assert!((0.0..1.0).contains(&value));
        }
    }

    #[test]
    fn states_round_trip() {
        for state in ALL_STATES {
            assert_eq!(SyncState::from_value(state.value()), Some(state));
        }
    }
}
