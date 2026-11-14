//! Every store under one data root, opened as `Daemon.__init__` opens them.
//!
//! The data root (`RELAY_ORCHESTRATOR_DATA_ROOT`, default
//! `~/Library/Application Support/relay-runner/orchestrator`) holds the
//! daemon's ledgers; its parent, the state root, holds the General task
//! ledger and the personal-storage catalog. Graphify is opened on demand, as
//! the program routes open it, so starting a daemon leaves an empty
//! `graphify.db` from an earlier release as it was.

use std::path::{Path, PathBuf};

use crate::Result;
use crate::commands::CommandStore;
use crate::continuity::ContinuityReportStore;
use crate::followups::FollowupProposalStore;
use crate::general_work::GeneralWorkStore;
use crate::graphify::GraphifyStore;
use crate::messenger::MessengerOutcomeStore;
use crate::personal_catalog::PersonalCatalog;
use crate::queue_drains::QueueDrainStore;
use crate::runs::RunsStore;
use crate::sessions::SessionStore;
use crate::sql;

/// The database files under the data root, in the order the daemon opens them.
pub const DATA_ROOT_DATABASES: [&str; 8] = [
    "runs.db",
    "queue_drains.db",
    "orchestrator_sessions.db",
    "orchestrator_commands.db",
    "messenger_outcomes.db",
    "followup_proposals.db",
    "continuity_reports.db",
    "graphify.db",
];

/// `_data_root()`: `RELAY_ORCHESTRATOR_DATA_ROOT`, or the installed location.
pub fn data_root() -> PathBuf {
    match std::env::var("RELAY_ORCHESTRATOR_DATA_ROOT") {
        Ok(configured) if !configured.is_empty() => PathBuf::from(sql::expand_user(&configured)),
        _ => PathBuf::from(sql::expand_user(
            "~/Library/Application Support/relay-runner/orchestrator",
        )),
    }
}

/// The state root: the data root's parent when it is named `orchestrator`.
pub fn state_root(data_root: &Path) -> PathBuf {
    if data_root
        .file_name()
        .is_some_and(|name| name == "orchestrator")
    {
        data_root
            .parent()
            .map_or_else(|| data_root.to_path_buf(), Path::to_path_buf)
    } else {
        data_root.to_path_buf()
    }
}

pub struct DaemonStores {
    pub data_root: PathBuf,
    pub runs: RunsStore,
    pub queue_drains: QueueDrainStore,
    pub orchestrator_sessions: SessionStore,
    pub orchestrator_commands: CommandStore,
    pub messenger_outcomes: MessengerOutcomeStore,
    pub followup_proposals: FollowupProposalStore,
    pub continuity_reports: ContinuityReportStore,
    pub general_work: GeneralWorkStore,
    pub personal_catalog: PersonalCatalog,
    pub graphify_path: PathBuf,
}

impl DaemonStores {
    pub fn open(data_root: &Path) -> Result<Self> {
        let state = state_root(data_root);
        Ok(Self {
            data_root: data_root.to_path_buf(),
            runs: RunsStore::open(
                &data_root.join("runs.db"),
                Some(&data_root.join("runs.json")),
            )?,
            queue_drains: QueueDrainStore::open(&data_root.join("queue_drains.db"))?,
            orchestrator_sessions: SessionStore::open(&data_root.join("orchestrator_sessions.db"))?,
            orchestrator_commands: CommandStore::open(&data_root.join("orchestrator_commands.db"))?,
            messenger_outcomes: MessengerOutcomeStore::open(
                &data_root.join("messenger_outcomes.db"),
            )?,
            followup_proposals: FollowupProposalStore::open(
                &data_root.join("followup_proposals.db"),
            )?,
            continuity_reports: ContinuityReportStore::open(
                &data_root.join("continuity_reports.db"),
            )?,
            personal_catalog: PersonalCatalog::open(&state)?,
            general_work: GeneralWorkStore::open(&state)?,
            graphify_path: data_root.join("graphify.db"),
        })
    }

    /// Opens the program index, creating its schema in place.
    pub fn graphify(&self) -> Result<GraphifyStore> {
        GraphifyStore::open(&self.graphify_path)
    }
}
