//! `services/artifact_retention.py`: the terminal-count retention policy,
//! snapshot leases, GitHub archival and the archived-history reads.
//!
//! SKELETON (RR-495 coordination): the public types and method signatures
//! below are the interface other part 2 modules compile against. The bodies
//! are filled in by the retention port.

use std::path::PathBuf;

use relay_intents::json::Dict;

use crate::Result;
use crate::instant::Instant;
use crate::store::{ArtifactStore, FailureInjector, Snapshot, WriteResult};
use crate::sync::{ArtifactSyncEngine, SyncResult};

pub const RETENTION_POLICY: &str = "terminal-count-v1";
pub const RETENTION_PLAN_SCHEMA_VERSION: i64 = 1;
pub const TERMINAL_RETENTION_LIMIT: usize = 25;
pub const CATALOG_SCHEMA_VERSION: i64 = 1;
pub const LEASE_SCHEMA_VERSION: i64 = 1;
pub const RETENTION_TRANSACTION_SCHEMA_VERSION: i64 = 1;

/// `RetentionState`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RetentionState {
    MaterializedRecent,
    MaterializedExempt,
    ArchiveEligible,
    ArchivePendingSync,
    Archived,
    RestorePendingFetch,
    RestorePendingSync,
    Conflict,
    DeletedTombstone,
}

impl RetentionState {
    pub fn value(self) -> &'static str {
        match self {
            RetentionState::MaterializedRecent => "materialized_recent",
            RetentionState::MaterializedExempt => "materialized_exempt",
            RetentionState::ArchiveEligible => "archive_eligible",
            RetentionState::ArchivePendingSync => "archive_pending_sync",
            RetentionState::Archived => "archived",
            RetentionState::RestorePendingFetch => "restore_pending_fetch",
            RetentionState::RestorePendingSync => "restore_pending_sync",
            RetentionState::Conflict => "conflict",
            RetentionState::DeletedTombstone => "deleted_tombstone",
        }
    }
}

/// `HistoryAvailability`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HistoryAvailability {
    Available,
    NeedsNetwork,
    Tampered,
    NotFound,
}

impl HistoryAvailability {
    pub fn value(self) -> &'static str {
        match self {
            HistoryAvailability::Available => "available",
            HistoryAvailability::NeedsNetwork => "needs_network",
            HistoryAvailability::Tampered => "tampered",
            HistoryAvailability::NotFound => "not_found",
        }
    }
}

/// `SnapshotLease`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SnapshotLease {
    pub lease_id: String,
    pub project_id: String,
    pub ticket_id: String,
    pub artifact_id: String,
    pub artifact_head: String,
    pub run_id: String,
    pub role: String,
    pub provider: String,
    pub attachment_paths: Vec<String>,
    pub created_at: Instant,
    pub heartbeat_at: Instant,
    /// `"active"` or `"released"`.
    pub state: String,
    pub released_at: Option<Instant>,
    pub terminal_reason: Option<String>,
}

/// `RetentionTicket`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RetentionTicket {
    pub ticket_id: String,
    pub artifact_id: String,
    pub title: String,
    pub status: String,
    pub activity_at: Instant,
    pub path: String,
    pub blob_id: String,
    pub source_commit: String,
    pub dependencies: Vec<String>,
    pub attachment_paths: Vec<String>,
    pub exemptions: Vec<String>,
    pub materialized: bool,
}

/// `RetentionPlan`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RetentionPlan {
    pub schema_version: i64,
    pub policy: String,
    pub limit: usize,
    pub project_id: String,
    pub artifact_head: String,
    pub evaluated_at: Instant,
    pub candidates: Vec<RetentionTicket>,
    pub retained_terminal: Vec<RetentionTicket>,
    pub nonterminal: Vec<RetentionTicket>,
    pub materialize: Vec<RetentionTicket>,
    pub exempt: Vec<RetentionTicket>,
    pub ranked_terminal: Vec<RetentionTicket>,
}

fn ids(tickets: &[RetentionTicket]) -> Vec<String> {
    tickets.iter().map(|ticket| ticket.ticket_id.clone()).collect()
}

impl RetentionPlan {
    pub fn candidate_ids(&self) -> Vec<String> {
        ids(&self.candidates)
    }

    pub fn retained_terminal_ids(&self) -> Vec<String> {
        ids(&self.retained_terminal)
    }

    pub fn nonterminal_ids(&self) -> Vec<String> {
        ids(&self.nonterminal)
    }

    pub fn materialize_ids(&self) -> Vec<String> {
        ids(&self.materialize)
    }

    /// `{ticket_id: exemptions}` in `exempt` order.
    pub fn temporary_overage(&self) -> Vec<(String, Vec<String>)> {
        self.exempt
            .iter()
            .map(|ticket| (ticket.ticket_id.clone(), ticket.exemptions.clone()))
            .collect()
    }
}

/// `ArchiveResult`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveResult {
    pub state: RetentionState,
    pub write: Option<WriteResult>,
    pub ticket_ids: Vec<String>,
    pub warnings: Vec<String>,
    pub recovery: Option<String>,
}

/// `HistoricalCard`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoricalCard {
    pub artifact_id: String,
    pub ticket_id: String,
    pub title: String,
    pub status: String,
    pub activity_at: Instant,
    pub state: RetentionState,
    pub attachment_count: i64,
    pub attachment_bytes: i64,
}

/// `HistoricalDetail`.
#[derive(Clone, Debug)]
pub struct HistoricalDetail {
    pub availability: HistoryAvailability,
    pub card: Option<HistoricalCard>,
    pub ticket_bytes: Option<Vec<u8>>,
    pub attachments: Vec<Dict>,
    pub recovery: Option<String>,
}

/// `HistoricalAttachment`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoricalAttachment {
    pub artifact_id: String,
    pub ticket_id: String,
    pub filename: String,
    pub mime_type: String,
    pub content: Vec<u8>,
    pub blob_id: String,
}

/// `StorageMetrics`.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct StorageMetrics {
    pub materialized_worktree_bytes: i64,
    pub materialized_file_count: i64,
    pub materialized_ticket_bytes: i64,
    pub materialized_ticket_count: i64,
    pub materialized_attachment_bytes: i64,
    pub materialized_attachment_count: i64,
    pub retained_terminal_count: i64,
    pub nonterminal_count: i64,
    pub temporary_overage_count: i64,
    pub remotely_backed_history_count: i64,
    pub reachable_git_object_bytes: i64,
    pub database_bytes: i64,
    pub run_log_bytes: i64,
    pub index_bytes: i64,
    pub cache_bytes: i64,
    pub run_database_log_bytes: i64,
    pub derived_index_cache_bytes: i64,
    pub reclaimable_estimate_bytes: i64,
}

/// `ArchiveRemoteConfirmation`: user-approved exposure of one exact,
/// existing GitHub remote.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveRemoteConfirmation {
    pub service: String,
    pub remote_name: String,
    pub remote_url_sha256: String,
    pub push_url_sha256: String,
    pub exposure_confirmed: bool,
}

/// A `deepen(commit_id)` callback, as the daemon builds it from
/// `ArtifactSyncEngine::fetch_historical_object`.
pub type Deepen<'d> = &'d dyn Fn(&str) -> Result<()>;

/// `_configured_remote_urls`: the fetch URL and the single push URL.
#[allow(unused_variables, clippy::todo)]
pub fn configured_remote_urls(store: &ArtifactStore, remote_name: &str) -> Result<(String, String)> {
    todo!("retention port")
}

/// `confirm_github_remote`.
#[allow(unused_variables, clippy::todo)]
pub fn confirm_github_remote(
    store: &ArtifactStore,
    remote_name: &str,
    exposure_confirmed: bool,
) -> Result<ArchiveRemoteConfirmation> {
    todo!("retention port")
}

/// `SnapshotLeaseStore`: durable, provider-neutral archive exemptions for
/// worker snapshots, in `<project state>/snapshot-leases.json`.
#[derive(Clone, Debug)]
pub struct SnapshotLeaseStore {
    pub project_id: String,
    pub path: PathBuf,
    pub lock_path: PathBuf,
}

/// `SnapshotLeaseStore.acquire`'s keyword arguments.
#[derive(Clone, Debug, Default)]
pub struct LeaseRequest {
    pub lease_id: String,
    pub ticket_id: String,
    pub artifact_id: String,
    pub artifact_head: String,
    pub run_id: String,
    pub role: String,
    pub provider: String,
    pub attachment_paths: Vec<String>,
    pub now: Option<Instant>,
}

#[allow(unused_variables, clippy::todo)]
impl SnapshotLeaseStore {
    pub fn new(store: &ArtifactStore) -> Self {
        Self {
            project_id: store.project_id.clone(),
            path: store.project_state.join("snapshot-leases.json"),
            lock_path: store.project_state.join("snapshot-leases.lock"),
        }
    }

    pub fn acquire(&self, request: &LeaseRequest) -> Result<SnapshotLease> {
        todo!("retention port")
    }

    pub fn heartbeat(&self, lease_id: &str, now: Option<Instant>) -> Result<SnapshotLease> {
        todo!("retention port")
    }

    pub fn release(
        &self,
        lease_id: &str,
        terminal_reason: &str,
        now: Option<Instant>,
    ) -> Result<SnapshotLease> {
        todo!("retention port")
    }

    /// Active leases sorted by lease ID.
    pub fn active(&self) -> Result<Vec<SnapshotLease>> {
        todo!("retention port")
    }

    /// The ticket IDs of active leases, sorted.
    pub fn active_ticket_ids(&self) -> Result<Vec<String>> {
        todo!("retention port")
    }
}

/// `ArtifactRetentionManager`'s keyword arguments other than the store.
pub struct RetentionOptions<'s> {
    pub lease_store: Option<SnapshotLeaseStore>,
    /// `local_only`, `enabled` or `paused`.
    pub remote_mode: String,
    pub remote_confirmation: Option<ArchiveRemoteConfirmation>,
    pub synchronizer: Option<&'s ArtifactSyncEngine<'s>>,
    pub enabled: bool,
    pub now: Option<Box<dyn Fn() -> Instant + Send + Sync>>,
    pub failure_injector: Option<FailureInjector>,
}

impl Default for RetentionOptions<'_> {
    fn default() -> Self {
        Self {
            lease_store: None,
            remote_mode: "local_only".to_string(),
            remote_confirmation: None,
            synchronizer: None,
            enabled: false,
            now: None,
            failure_injector: None,
        }
    }
}

/// `ArtifactRetentionManager`.
pub struct ArtifactRetentionManager<'s> {
    pub store: &'s ArtifactStore,
    pub lease_store: SnapshotLeaseStore,
    pub remote_mode: String,
    pub remote_confirmation: Option<ArchiveRemoteConfirmation>,
    pub synchronizer: Option<&'s ArtifactSyncEngine<'s>>,
    pub enabled: bool,
    pub transaction_path: PathBuf,
    now: Box<dyn Fn() -> Instant + Send + Sync>,
    failure_injector: Option<FailureInjector>,
}

/// Where `restore`, `reopen` and the history reads may fetch from.
#[derive(Clone, Copy, Default)]
pub struct HistoryAccess<'d> {
    pub online: bool,
    pub deepen: Option<Deepen<'d>>,
}

/// `restore` / `reopen` / `delete` / `archive`'s event keyword arguments.
#[derive(Clone, Debug, Default)]
pub struct EventArgs {
    pub event_id: String,
    pub device_id: String,
    /// Python's default differs per method: `system` for `archive`, `user`
    /// for the others.
    pub actor_type: Option<String>,
    pub provider: Option<String>,
    /// `restored_at`, `reopened_at` or `deleted_at`.
    pub at: Option<Instant>,
}

/// `storage_metrics`' keyword arguments.
#[derive(Clone, Debug, Default)]
pub struct StoragePaths {
    pub run_paths: Vec<PathBuf>,
    pub index_cache_paths: Vec<PathBuf>,
    pub database_paths: Vec<PathBuf>,
    pub run_log_paths: Vec<PathBuf>,
    pub index_paths: Vec<PathBuf>,
    pub cache_paths: Vec<PathBuf>,
}

#[allow(unused_variables, clippy::todo)]
impl<'s> ArtifactRetentionManager<'s> {
    pub fn new(store: &'s ArtifactStore, options: RetentionOptions<'s>) -> Result<Self> {
        todo!("retention port")
    }

    pub fn preview(&self, evaluated_at: Option<Instant>) -> Result<RetentionPlan> {
        todo!("retention port")
    }

    pub fn archive(
        &self,
        plan: &RetentionPlan,
        event: &EventArgs,
        synchronizer: Option<&ArtifactSyncEngine<'_>>,
    ) -> Result<ArchiveResult> {
        todo!("retention port")
    }

    pub fn recover_archive(
        &self,
        synchronizer: Option<&ArtifactSyncEngine<'_>>,
    ) -> Result<Option<ArchiveResult>> {
        todo!("retention port")
    }

    pub fn recover_from_remote(
        &self,
        synchronizer: Option<&ArtifactSyncEngine<'_>>,
    ) -> Result<SyncResult> {
        todo!("retention port")
    }

    pub fn historical_search(&self, query: &str) -> Result<Vec<HistoricalCard>> {
        todo!("retention port")
    }

    pub fn historical_detail(
        &self,
        artifact_id: &str,
        access: HistoryAccess<'_>,
    ) -> Result<HistoricalDetail> {
        todo!("retention port")
    }

    pub fn historical_attachment(
        &self,
        artifact_id: &str,
        filename: &str,
        access: HistoryAccess<'_>,
    ) -> Result<HistoricalAttachment> {
        todo!("retention port")
    }

    pub fn restore(
        &self,
        artifact_id: &str,
        event: &EventArgs,
        access: HistoryAccess<'_>,
    ) -> Result<ArchiveResult> {
        todo!("retention port")
    }

    pub fn reopen(
        &self,
        artifact_id: &str,
        event: &EventArgs,
        access: HistoryAccess<'_>,
    ) -> Result<ArchiveResult> {
        todo!("retention port")
    }

    pub fn delete(&self, ticket_id: &str, event: &EventArgs) -> Result<ArchiveResult> {
        todo!("retention port")
    }

    pub fn dependency_satisfied(
        &self,
        dependency_id: &str,
        snapshot: Option<&Snapshot>,
    ) -> Result<bool> {
        todo!("retention port")
    }

    pub fn dependency_execution_mode(
        &self,
        dependency_id: &str,
        snapshot: Option<&Snapshot>,
    ) -> Result<Option<String>> {
        todo!("retention port")
    }

    /// `transaction_status()`, as the JSON mapping Python returns.
    pub fn transaction_status(&self) -> Result<Dict> {
        todo!("retention port")
    }

    pub fn storage_metrics(&self, paths: &StoragePaths) -> Result<StorageMetrics> {
        todo!("retention port")
    }
}
