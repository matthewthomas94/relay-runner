//! `services/artifact_sync.py`: exact-ref, no-force synchronization of one
//! project's `refs/heads/relay/artifacts` with one explicitly configured
//! remote.
//!
//! SKELETON (RR-495 coordination): the public types and method signatures
//! below are the interface other part 2 modules compile against. The bodies
//! are filled in by the sync port.

use std::path::PathBuf;

use crate::Result;
use crate::store::{ArtifactStore, FailureInjector};

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
}

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
            jitter: Box::new(|| 0.5),
            failure_injector: None,
        }
    }
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

#[allow(unused_variables, clippy::todo)]
impl<'s> ArtifactSyncEngine<'s> {
    pub fn new(store: &'s ArtifactStore, options: SyncOptions) -> Result<Self> {
        todo!("sync port")
    }

    pub fn status(&self) -> Result<SyncResult> {
        todo!("sync port")
    }

    pub fn sync(&self) -> Result<SyncResult> {
        todo!("sync port")
    }

    pub fn sync_confirmed(
        &self,
        expected_remote_url_sha256: &str,
        expected_push_url_sha256: &str,
    ) -> Result<SyncResult> {
        todo!("sync port")
    }

    pub fn publish_initial(&self, confirmed: bool) -> Result<SyncResult> {
        todo!("sync port")
    }

    pub fn publish_prepared(
        &self,
        candidate_head: &str,
        expected_remote_head: &str,
        proofs: &[RemoteProof],
        expected_remote_url_sha256: Option<&str>,
        expected_push_url_sha256: Option<&str>,
    ) -> Result<SyncResult> {
        todo!("sync port")
    }

    pub fn recover_exact_ref(
        &self,
        expected_remote_url_sha256: &str,
        validate_head: Option<&dyn Fn(&str) -> Result<()>>,
    ) -> Result<SyncResult> {
        todo!("sync port")
    }

    pub fn fetch_historical_object(
        &self,
        commit_id: &str,
        expected_remote_url_sha256: &str,
    ) -> Result<()> {
        todo!("sync port")
    }

    pub fn resolve_conflict(
        &self,
        report: &ConflictReport,
        decisions: &[(String, Decision)],
        resolution_event_id: &str,
        device_id: &str,
        actor_type: &str,
        provider: Option<&str>,
    ) -> Result<SyncResult> {
        todo!("sync port")
    }

    /// `ArtifactSyncEngine.classify_git_failure` (a static method).
    pub fn classify_git_failure(message: &str, operation: &str) -> (SyncState, String) {
        todo!("sync port")
    }
}
