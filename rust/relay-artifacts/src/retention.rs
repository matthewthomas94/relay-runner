//! `services/artifact_retention.py`: the terminal-count retention policy,
//! snapshot leases, GitHub archival and the archived-history reads, plus the
//! daemon's retention and history JSON payloads from `services/orchestrator.py`.
//!
//! Retention changes only the project-owned artifact ref, through the store.
//! The source branch, index, worktree and configured remotes stay outside it.
//! Every file it leaves behind is Python's own form, so the two can take
//! turns: `snapshot-leases.json` and `retention-transaction.json` under the
//! project state directory (canonical JSON, sorted keys), the shared flock on
//! `snapshot-leases.lock`, the scratch refs under
//! `refs/relay-runner/retention/<project>/`, and the archive catalog
//! `.orchestrator/archive-index.jsonl`, one canonical JSON object per line in
//! artifact-ID order.
//!
//! Known differences, each failing where Python fails:
//!
//! - A missing key in a corrupt lease file or catalog entry is Python's
//!   `KeyError`; it is reported here as `ValueError` with the same `str()`.
//! - The verified-catalog cache (RR-449) is kept per project (repository and
//!   project state path) rather than per `ArtifactStore` object. Git objects
//!   are immutable, so an entry verified at an ancestor head with the same
//!   catalog bytes is still verified; only how often it is checked differs.
//! - History search folds case with `to_lowercase` (plus `ß` to `ss`) where
//!   Python uses `str.casefold`; they differ only for a few letters.
//! - An unreadable lease or transaction file names Rust's I/O error, and a
//!   JSON decode failure is reported without its position.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, LazyLock, Mutex};
use std::thread::ThreadId;

use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256::hex_digest;

use crate::catalog::{self, DEFAULT_ACTIVITY_FIELDS};
use crate::instant::Instant;
use crate::store::{
    self, ArtifactStore, Entries, FailureInjector, Mutation, Operation, Snapshot, TreeEntry,
    WriteResult,
};
use crate::sync::{ArtifactSyncEngine, RemoteProof, SyncResult, SyncState};
use crate::{Error, ErrorKind, Result, pystr};

pub const RETENTION_POLICY: &str = "terminal-count-v1";
pub const RETENTION_PLAN_SCHEMA_VERSION: i64 = 1;
pub const TERMINAL_RETENTION_LIMIT: usize = 25;
pub const CATALOG_SCHEMA_VERSION: i64 = 1;
pub const LEASE_SCHEMA_VERSION: i64 = 1;
pub const RETENTION_TRANSACTION_SCHEMA_VERSION: i64 = 1;

/// `ACTIVITY_FIELDS`: the front-matter instants whose latest value ranks a
/// ticket.
pub const ACTIVITY_FIELDS: [&str; 12] = DEFAULT_ACTIVITY_FIELDS;

const ACTIVE_RUN_STATES: [&str; 5] = [
    "claimed",
    "running",
    "awaiting_review",
    "reviewing",
    "merge_conflict",
];
const TERMINAL_STATUSES: [&str; 3] = ["done", "canceled", "cancelled"];
const CATALOG_PATH: &str = ".orchestrator/archive-index.jsonl";
const DELETE_WARNING: &str = "Routine Delete is recoverable and does not erase Git history. Rotate exposed secrets and use a separately reviewed coordinated purge if privacy erasure is required.";

/// `_MissingHistoricalObject`, carried as an error with a sentinel message
/// until the caller that Python catches it in turns it into its own result.
const MISSING_HISTORICAL_OBJECT: &str = "\u{0}_MissingHistoricalObject";

fn missing_historical_object() -> Error {
    Error::new(ErrorKind::Runtime, MISSING_HISTORICAL_OBJECT)
}

/// Whether `error` is Python's private `_MissingHistoricalObject`, which
/// escapes a few public methods unconverted (its `str()` is empty).
pub fn is_missing_historical_object(error: &Error) -> bool {
    error.kind == ErrorKind::Runtime && error.message == MISSING_HISTORICAL_OBJECT
}

fn validation(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::Validation, message)
}

fn concurrent(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::ConcurrentUpdate, message)
}

fn key_error(key: &str) -> Error {
    Error::value(pystr::repr(key))
}

/// Python's `except (ArtifactValidationError, CatalogSemanticError)`.
fn is_validation_or_semantic(error: &Error) -> bool {
    error.kind.is_validation() || error.kind == ErrorKind::CatalogSemantic
}

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
    pub const ALL: [RetentionState; 9] = [
        RetentionState::MaterializedRecent,
        RetentionState::MaterializedExempt,
        RetentionState::ArchiveEligible,
        RetentionState::ArchivePendingSync,
        RetentionState::Archived,
        RetentionState::RestorePendingFetch,
        RetentionState::RestorePendingSync,
        RetentionState::Conflict,
        RetentionState::DeletedTombstone,
    ];

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

    /// `RetentionState(value)`, with the enum's `ValueError` message.
    pub fn from_value(value: &str) -> Result<Self> {
        Self::ALL
            .into_iter()
            .find(|state| state.value() == value)
            .ok_or_else(|| {
                Error::value(format!(
                    "{} is not a valid RetentionState",
                    pystr::repr(value)
                ))
            })
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
    tickets
        .iter()
        .map(|ticket| ticket.ticket_id.clone())
        .collect()
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

/// `_plan_identity`.
type PlanIdentity = (
    i64,
    String,
    usize,
    Vec<String>,
    Vec<String>,
    Vec<String>,
    Vec<String>,
    Vec<(String, Vec<String>)>,
);

fn plan_identity(plan: &RetentionPlan) -> PlanIdentity {
    (
        plan.schema_version,
        plan.policy.clone(),
        plan.limit,
        plan.candidate_ids(),
        plan.retained_terminal_ids(),
        plan.nonterminal_ids(),
        plan.materialize_ids(),
        plan.temporary_overage(),
    )
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

impl ArchiveResult {
    fn new(state: RetentionState, write: Option<WriteResult>, ticket_ids: Vec<String>) -> Self {
        Self {
            state,
            write,
            ticket_ids,
            warnings: Vec::new(),
            recovery: None,
        }
    }

    fn pending(ticket_ids: Vec<String>, recovery: String) -> Self {
        Self {
            recovery: Some(recovery),
            ..Self::new(RetentionState::ArchivePendingSync, None, ticket_ids)
        }
    }
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

impl HistoricalDetail {
    fn unavailable(
        availability: HistoryAvailability,
        card: Option<HistoricalCard>,
        recovery: Option<String>,
    ) -> Self {
        Self {
            availability,
            card,
            ticket_bytes: None,
            attachments: Vec::new(),
            recovery,
        }
    }
}

/// `DependencyHistoryUnavailable(dependency_id, detail)`.
fn dependency_history_unavailable(dependency_id: &str, detail: &HistoricalDetail) -> Error {
    Error::new(
        ErrorKind::DependencyHistoryUnavailable,
        detail.recovery.clone().unwrap_or_else(|| {
            format!(
                "archived dependency {dependency_id} is {}",
                detail.availability.value()
            )
        }),
    )
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

impl StorageMetrics {
    /// `dataclasses.asdict(metrics)`, in field order.
    pub fn as_dict(&self) -> Dict {
        let mut result = Dict::new();
        for (key, value) in [
            (
                "materialized_worktree_bytes",
                self.materialized_worktree_bytes,
            ),
            ("materialized_file_count", self.materialized_file_count),
            ("materialized_ticket_bytes", self.materialized_ticket_bytes),
            ("materialized_ticket_count", self.materialized_ticket_count),
            (
                "materialized_attachment_bytes",
                self.materialized_attachment_bytes,
            ),
            (
                "materialized_attachment_count",
                self.materialized_attachment_count,
            ),
            ("retained_terminal_count", self.retained_terminal_count),
            ("nonterminal_count", self.nonterminal_count),
            ("temporary_overage_count", self.temporary_overage_count),
            (
                "remotely_backed_history_count",
                self.remotely_backed_history_count,
            ),
            (
                "reachable_git_object_bytes",
                self.reachable_git_object_bytes,
            ),
            ("database_bytes", self.database_bytes),
            ("run_log_bytes", self.run_log_bytes),
            ("index_bytes", self.index_bytes),
            ("cache_bytes", self.cache_bytes),
            ("run_database_log_bytes", self.run_database_log_bytes),
            ("derived_index_cache_bytes", self.derived_index_cache_bytes),
            (
                "reclaimable_estimate_bytes",
                self.reclaimable_estimate_bytes,
            ),
        ] {
            result.insert(key, value);
        }
        result
    }
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

impl ArchiveRemoteConfirmation {
    /// `dataclasses.asdict(confirmation)`.
    pub fn as_dict(&self) -> Dict {
        let mut result = Dict::new();
        result.insert("service", self.service.as_str());
        result.insert("remote_name", self.remote_name.as_str());
        result.insert("remote_url_sha256", self.remote_url_sha256.as_str());
        result.insert("push_url_sha256", self.push_url_sha256.as_str());
        result.insert("exposure_confirmed", self.exposure_confirmed);
        result
    }
}

/// A `deepen(commit_id)` callback, as the daemon builds it from
/// `ArtifactSyncEngine::fetch_historical_object`.
pub type Deepen<'d> = &'d dyn Fn(&str) -> Result<()>;

// -- small Python-compatible helpers -----------------------------------------

fn is_hex(value: &str, lengths: &[usize]) -> bool {
    lengths.contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// `re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value)`.
fn is_object_id(value: &str) -> bool {
    is_hex(value, &[40, 64])
}

/// `re.fullmatch(r"[A-Za-z0-9._-]{1,128}", value)`.
fn is_remote_name(value: &str) -> bool {
    (1..=128).contains(&value.chars().count())
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._-".contains(character))
}

/// `_SAFE_ID_RE.fullmatch(value)`: `^[A-Za-z0-9_.:-]{1,160}$`.
fn is_safe_id(value: &str) -> bool {
    (1..=160).contains(&value.chars().count())
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "_.:-".contains(character))
}

fn validate_safe_id<'v>(value: &'v str, label: &str) -> Result<&'v str> {
    if is_safe_id(value) {
        Ok(value)
    } else {
        Err(validation(format!(
            "invalid {label}: {}",
            pystr::repr(value)
        )))
    }
}

/// One character against an ASCII letter under `re.IGNORECASE`: the Unicode
/// characters whose simple case mapping is that letter match too.
fn ignorecase_letter(character: char, lower: char) -> bool {
    character.to_ascii_lowercase() == lower
        || match lower {
            'i' => matches!(character, '\u{130}' | '\u{131}'),
            's' => character == '\u{17f}',
            'k' => character == '\u{212a}',
            _ => false,
        }
}

/// `[A-Za-z0-9_.-]` under `re.IGNORECASE`.
fn ignorecase_repository_character(character: char) -> bool {
    character.is_ascii_alphanumeric()
        || "_.-".contains(character)
        || matches!(character, '\u{130}' | '\u{131}' | '\u{17f}' | '\u{212a}')
}

fn ignorecase_prefix<'v>(value: &'v str, literal: &str) -> Option<&'v str> {
    let mut characters = value.char_indices();
    for expected in literal.chars() {
        let (_, character) = characters.next()?;
        let matched = if expected.is_ascii_alphabetic() {
            ignorecase_letter(character, expected.to_ascii_lowercase())
        } else {
            character == expected
        };
        if !matched {
            return None;
        }
    }
    Some(characters.as_str())
}

/// `[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+` as a full match, case-insensitively.
fn is_repository(value: &str) -> bool {
    let Some((owner, name)) = value.split_once('/') else {
        return false;
    };
    [owner, name]
        .iter()
        .all(|part| !part.is_empty() && part.chars().all(ignorecase_repository_character))
}

/// `_is_github_url`.
fn is_github_url(value: &str) -> bool {
    [
        "https://github.com/",
        "ssh://git@github.com/",
        "git@github.com:",
    ]
    .iter()
    .any(|prefix| ignorecase_prefix(value, prefix).is_some_and(is_repository))
}

/// `_is_ticket_path`.
fn is_ticket_path(path: &str) -> bool {
    path.strip_prefix(".orchestrator/")
        .is_some_and(|rest| path.ends_with(".md") && !rest.contains('/'))
}

/// `PurePosixPath(path).name`.
fn posix_name(path: &str) -> &str {
    path.split('/')
        .rfind(|part| !part.is_empty() && *part != ".")
        .unwrap_or("")
}

/// `PurePosixPath(path).stem`.
fn posix_stem(path: &str) -> &str {
    let name = posix_name(path);
    match name.rfind('.') {
        Some(index) if !name[..index].trim_start_matches('.').is_empty() => &name[..index],
        _ => name,
    }
}

/// Front matter as `_front_matter` reads it: first-seen key order, a
/// repeated key keeping its last value.
type Front = Vec<(String, String)>;

fn front_get<'f>(front: &'f Front, key: &str) -> Option<&'f str> {
    front
        .iter()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value.as_str())
}

/// `_front_matter`.
fn front_matter(content: &[u8]) -> Result<Front> {
    let text =
        std::str::from_utf8(content).map_err(|_| validation("ticket front matter is not UTF-8"))?;
    let lines = pystr::splitlines(text);
    if lines.first().is_none_or(|line| pystr::strip(line) != "---") {
        return Err(validation("ticket has no front matter"));
    }
    let mut result = Front::new();
    for line in &lines[1..] {
        if pystr::strip(line) == "---" {
            return Ok(result);
        }
        let (key, found, value) = pystr::partition(line, ":");
        if found {
            let key = pystr::strip(key).to_string();
            let value = pystr::strip_quotes(pystr::strip(value)).to_string();
            match result.iter_mut().find(|(name, _)| *name == key) {
                Some(entry) => entry.1 = value,
                None => result.push((key, value)),
            }
        }
    }
    Err(validation("ticket front matter is not closed"))
}

/// `_set_front_matter_value`.
fn set_front_matter_value(content: &[u8], key: &str, value: &str) -> Result<Vec<u8>> {
    let text = pystr::decode_utf8(content)?;
    let mut lines: Vec<String> = pystr::splitlines(text)
        .into_iter()
        .map(str::to_string)
        .collect();
    let closing = lines
        .iter()
        .enumerate()
        .skip(1)
        .find(|(_, line)| pystr::strip(line) == "---")
        .map(|(index, _)| index)
        .ok_or_else(|| validation("ticket front matter is not closed"))?;
    let replacement = format!("{key}: {value}");
    let existing = (1..closing).find(|index| {
        let (name, found, _) = pystr::partition(&lines[*index], ":");
        found && pystr::strip(name) == key
    });
    match existing {
        Some(index) => lines[index] = replacement,
        None => lines.insert(closing, replacement),
    }
    Ok(pystr::join_lines_with_final_newline(&lines).into_bytes())
}

/// `_parse_list`.
fn parse_list(value: &str) -> Vec<String> {
    let mut stripped = pystr::strip(value);
    if stripped.is_empty() || stripped == "[]" {
        return Vec::new();
    }
    if stripped.starts_with('[') && stripped.ends_with(']') && stripped.len() >= 2 {
        stripped = &stripped[1..stripped.len() - 1];
    }
    stripped
        .split(',')
        .map(|item| pystr::strip_quotes(pystr::strip(item)))
        .filter(|item| !item.is_empty())
        .map(str::to_string)
        .collect()
}

/// `_parse_bool`.
fn parse_bool(value: &str) -> bool {
    matches!(
        pystr::strip(value).to_lowercase().as_str(),
        "true" | "yes" | "1"
    )
}

/// `_canonical_status`.
fn canonical_status(front: &Front) -> String {
    if parse_bool(front_get(front, "canceled").unwrap_or("false")) {
        return "canceled".to_string();
    }
    front_get(front, "status").unwrap_or("backlog").to_string()
}

/// `_is_terminal`.
fn is_terminal(status: &str) -> bool {
    TERMINAL_STATUSES.contains(&pystr::strip(status).to_lowercase().as_str())
}

/// `_parse_instant`.
fn parse_instant(value: &str) -> Result<Instant> {
    match Instant::fromisoformat_z(value) {
        Ok(Some(instant)) => Ok(instant),
        Ok(None) => Err(validation(format!(
            "activity instant has no UTC offset: {}",
            pystr::repr(value)
        ))),
        Err(error) if error.kind == ErrorKind::Value => Err(validation(format!(
            "invalid RFC 3339 activity instant: {}",
            pystr::repr(value)
        ))),
        Err(error) => Err(error),
    }
}

/// `_format_instant`.
fn format_instant(value: Instant) -> String {
    value.isoformat_micros_z()
}

/// `_canonical_json`.
fn canonical_json(value: &Value) -> String {
    json::dumps_compact_sorted_unicode(value)
}

/// `str(entry.get(key, default))`.
fn get_str(entry: &Dict, key: &str, default: &str) -> String {
    entry
        .get(key)
        .map_or_else(|| default.to_string(), Value::py_str)
}

/// `str(entry[key])`.
fn index_str(entry: &Dict, key: &str) -> Result<String> {
    entry
        .get(key)
        .map(Value::py_str)
        .ok_or_else(|| key_error(key))
}

/// `str.casefold()`, as far as Relay's titles need.
fn casefold(text: &str) -> String {
    text.to_lowercase().replace('ß', "ss")
}

fn strings(values: &[String]) -> Value {
    Value::List(
        values
            .iter()
            .map(|value| Value::Str(value.clone()))
            .collect(),
    )
}

fn random_hex() -> String {
    let mut bytes = [0u8; 16];
    let read = File::open("/dev/urandom").and_then(|mut source| source.read_exact(&mut bytes));
    if read.is_err() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        bytes = (nanos ^ (u128::from(std::process::id()) << 64)).to_le_bytes();
    }
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `path.with_name(path.name + f".{uuid4().hex}.tmp")`.
fn temporary_beside(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    path.with_file_name(format!("{name}.{}.tmp", random_hex()))
}

fn fsync_directory(path: &Path) -> Result<()> {
    File::open(path)?.sync_all()?;
    Ok(())
}

fn is_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink())
}

/// `[path for path in root.rglob("*") if path.is_file() and not
/// path.is_symlink()]`: symlinked directories are not descended into.
fn regular_files(root: &Path) -> Vec<PathBuf> {
    let mut result = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let Ok(children) = fs::read_dir(&directory) else {
            continue;
        };
        for child in children.flatten() {
            let path = child.path();
            let Ok(metadata) = fs::symlink_metadata(&path) else {
                continue;
            };
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                pending.push(path);
            } else if metadata.is_file() {
                result.push(path);
            }
        }
    }
    result
}

fn file_size(path: &Path) -> i64 {
    fs::metadata(path).map_or(0, |metadata| metadata.len() as i64)
}

/// `_disk_usage`.
fn disk_usage(path: &Path) -> i64 {
    if fs::metadata(path).is_err() || is_symlink(path) {
        return 0;
    }
    if path.is_file() {
        return file_size(path);
    }
    regular_files(path)
        .iter()
        .map(|child| file_size(child))
        .sum()
}

/// `_validate_transaction`'s and the confirmation's checks need SHA-256 hex.
fn sha256_text(text: &str) -> String {
    hex_digest(text.as_bytes())
}

// -- remotes -------------------------------------------------------------------

/// `_configured_remote_urls`: the fetch URL and the single push URL.
pub fn configured_remote_urls(
    store: &ArtifactStore,
    remote_name: &str,
) -> Result<(String, String)> {
    let fetch = store.git(&["remote", "get-url", remote_name], &[], None, &[0, 2, 128])?;
    let push = store.git(
        &["remote", "get-url", "--push", "--all", remote_name],
        &[],
        None,
        &[0, 2, 128],
    )?;
    let push_text = push.text();
    let push_urls = pystr::splitlines(&push_text);
    let fetch_url = pystr::strip(&fetch.text()).to_string();
    if fetch.status != 0 || fetch_url.is_empty() || push.status != 0 {
        return Err(validation(format!(
            "selected existing remote {} is unavailable; Relay will not create it",
            pystr::repr(remote_name)
        )));
    }
    if push_urls.len() != 1 || push_urls[0].is_empty() {
        return Err(validation(
            "terminal cleanup requires exactly one explicitly confirmed push destination",
        ));
    }
    Ok((fetch_url, push_urls[0].to_string()))
}

/// `confirm_github_remote`: bind explicit exposure consent to the selected
/// remote's current URL.
pub fn confirm_github_remote(
    store: &ArtifactStore,
    remote_name: &str,
    exposure_confirmed: bool,
) -> Result<ArchiveRemoteConfirmation> {
    if !exposure_confirmed {
        return Err(validation(
            "GitHub archival requires explicit confirmation that ticket content will be exposed",
        ));
    }
    if !is_remote_name(remote_name) {
        return Err(validation(format!(
            "invalid configured remote name: {}",
            pystr::repr(remote_name)
        )));
    }
    let (remote_url, push_url) = configured_remote_urls(store, remote_name)?;
    if !is_github_url(&remote_url) || !is_github_url(&push_url) {
        return Err(validation(
            "terminal cleanup requires an explicitly confirmed github.com remote for both fetch and push",
        ));
    }
    Ok(ArchiveRemoteConfirmation {
        service: "github".to_string(),
        remote_name: remote_name.to_string(),
        remote_url_sha256: sha256_text(&remote_url),
        push_url_sha256: sha256_text(&push_url),
        exposure_confirmed: true,
    })
}

// -- snapshot leases -------------------------------------------------------------

/// The process side of the lease lock: one owner thread at a time, which may
/// re-enter; the outermost entry also holds the cross-process `flock`.
#[derive(Default)]
struct ReentrantFileLock {
    state: Mutex<(Option<ThreadId>, usize, Option<File>)>,
    released: Condvar,
}

static LEASE_LOCKS: LazyLock<Mutex<HashMap<PathBuf, Arc<ReentrantFileLock>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

struct LeaseGuard {
    lock: Arc<ReentrantFileLock>,
}

impl Drop for LeaseGuard {
    fn drop(&mut self) {
        let mut state = self
            .lock
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        state.1 -= 1;
        if state.1 == 0 {
            if let Some(file) = state.2.take() {
                let _ = file.unlock();
            }
            state.0 = None;
            self.lock.released.notify_one();
        }
    }
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

/// `_lease_json`.
pub fn lease_json(lease: &SnapshotLease) -> Dict {
    let mut result = Dict::new();
    result.insert("lease_id", lease.lease_id.as_str());
    result.insert("project_id", lease.project_id.as_str());
    result.insert("ticket_id", lease.ticket_id.as_str());
    result.insert("artifact_id", lease.artifact_id.as_str());
    result.insert("artifact_head", lease.artifact_head.as_str());
    result.insert("run_id", lease.run_id.as_str());
    result.insert("role", lease.role.as_str());
    result.insert("provider", lease.provider.as_str());
    result.insert("attachment_paths", strings(&lease.attachment_paths));
    result.insert("created_at", format_instant(lease.created_at));
    result.insert("heartbeat_at", format_instant(lease.heartbeat_at));
    result.insert("state", lease.state.as_str());
    result.insert(
        "released_at",
        lease
            .released_at
            .map_or(Value::Null, |instant| Value::Str(format_instant(instant))),
    );
    result.insert(
        "terminal_reason",
        lease
            .terminal_reason
            .as_deref()
            .map_or(Value::Null, Value::from),
    );
    result
}

impl SnapshotLeaseStore {
    pub fn new(store: &ArtifactStore) -> Self {
        Self {
            project_id: store.project_id.clone(),
            path: store.project_state.join("snapshot-leases.json"),
            lock_path: store.project_state.join("snapshot-leases.lock"),
        }
    }

    pub fn acquire(&self, request: &LeaseRequest) -> Result<SnapshotLease> {
        for (value, label) in [
            (&request.lease_id, "lease ID"),
            (&request.ticket_id, "ticket ID"),
            (&request.artifact_id, "artifact ID"),
            (&request.run_id, "run ID"),
        ] {
            validate_safe_id(value, label)?;
        }
        if !["worker", "reviewer"].contains(&request.role.as_str()) {
            return Err(validation(format!(
                "invalid snapshot lease role: {}",
                pystr::repr(&request.role)
            )));
        }
        if !["codex", "claude"].contains(&request.provider.as_str()) {
            return Err(validation(format!(
                "invalid snapshot lease provider: {}",
                pystr::repr(&request.provider)
            )));
        }
        if !is_object_id(&request.artifact_head) {
            return Err(validation(
                "snapshot lease artifact head is not a Git object ID",
            ));
        }
        let normalized: Vec<String> = request
            .attachment_paths
            .iter()
            .cloned()
            .collect::<BTreeSet<String>>()
            .into_iter()
            .collect();
        let expected_prefix = format!(".orchestrator/attachments/{}/", request.ticket_id);
        for path in &normalized {
            if !path.starts_with(&expected_prefix) || posix_name(path).is_empty() {
                return Err(validation(format!(
                    "snapshot lease attachment is not owned by {}: {}",
                    request.ticket_id,
                    pystr::repr(path)
                )));
            }
        }
        let instant = request.now.unwrap_or_else(Instant::now);
        let proposed = SnapshotLease {
            lease_id: request.lease_id.clone(),
            project_id: self.project_id.clone(),
            ticket_id: request.ticket_id.clone(),
            artifact_id: request.artifact_id.clone(),
            artifact_head: request.artifact_head.clone(),
            run_id: request.run_id.clone(),
            role: request.role.clone(),
            provider: request.provider.clone(),
            attachment_paths: normalized,
            created_at: instant,
            heartbeat_at: instant,
            state: "active".to_string(),
            released_at: None,
            terminal_reason: None,
        };
        self.with_lock(|| {
            let mut leases = self.load_unlocked()?;
            if let Some(existing) = leases.get(&request.lease_id) {
                let comparable = SnapshotLease {
                    heartbeat_at: proposed.heartbeat_at,
                    created_at: proposed.created_at,
                    ..existing.clone()
                };
                if comparable != proposed {
                    return Err(validation(format!(
                        "snapshot lease ID {} was reused with different ownership",
                        pystr::repr(&request.lease_id)
                    )));
                }
                return Ok(existing.clone());
            }
            leases.insert(request.lease_id.clone(), proposed.clone());
            self.write_unlocked(&leases)?;
            Ok(proposed)
        })
    }

    pub fn heartbeat(&self, lease_id: &str, now: Option<Instant>) -> Result<SnapshotLease> {
        self.with_lock(|| {
            let mut leases = self.load_unlocked()?;
            let lease = leases
                .get(lease_id)
                .filter(|lease| lease.state == "active")
                .cloned()
                .ok_or_else(|| {
                    validation(format!(
                        "snapshot lease {} is not active",
                        pystr::repr(lease_id)
                    ))
                })?;
            let updated = SnapshotLease {
                heartbeat_at: now.unwrap_or_else(Instant::now),
                ..lease
            };
            leases.insert(lease_id.to_string(), updated.clone());
            self.write_unlocked(&leases)?;
            Ok(updated)
        })
    }

    pub fn release(
        &self,
        lease_id: &str,
        terminal_reason: &str,
        now: Option<Instant>,
    ) -> Result<SnapshotLease> {
        if pystr::strip(terminal_reason).is_empty() || terminal_reason.chars().count() > 200 {
            return Err(validation(
                "snapshot lease release needs a bounded terminal reason",
            ));
        }
        self.with_lock(|| {
            let mut leases = self.load_unlocked()?;
            let lease = leases.get(lease_id).cloned().ok_or_else(|| {
                validation(format!("unknown snapshot lease {}", pystr::repr(lease_id)))
            })?;
            if lease.state == "released" {
                if lease.terminal_reason.as_deref() != Some(terminal_reason) {
                    return Err(validation(format!(
                        "snapshot lease {} was already released for another reason",
                        pystr::repr(lease_id)
                    )));
                }
                return Ok(lease);
            }
            let updated = SnapshotLease {
                state: "released".to_string(),
                released_at: Some(now.unwrap_or_else(Instant::now)),
                terminal_reason: Some(terminal_reason.to_string()),
                ..lease
            };
            leases.insert(lease_id.to_string(), updated.clone());
            self.write_unlocked(&leases)?;
            Ok(updated)
        })
    }

    /// Active leases sorted by lease ID.
    pub fn active(&self) -> Result<Vec<SnapshotLease>> {
        self.with_lock(|| {
            Ok(self
                .load_unlocked()?
                .into_values()
                .filter(|lease| lease.state == "active")
                .collect())
        })
    }

    /// The ticket IDs of active leases, sorted. Deliberately no time expiry:
    /// daemon recovery must prove a terminal run before releasing a lease.
    pub fn active_ticket_ids(&self) -> Result<Vec<String>> {
        let ids: BTreeSet<String> = self
            .active()?
            .into_iter()
            .map(|lease| lease.ticket_id)
            .collect();
        Ok(ids.into_iter().collect())
    }

    /// `_locked()`: the process lock, re-entrant per thread, and the
    /// cross-process `flock` on `snapshot-leases.lock`.
    pub fn with_lock<T>(&self, work: impl FnOnce() -> Result<T>) -> Result<T> {
        if let Some(parent) = self.lock_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let lock = LEASE_LOCKS
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .entry(self.lock_path.clone())
            .or_default()
            .clone();
        let me = std::thread::current().id();
        let outermost = {
            let mut state = lock
                .state
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            while state.0.is_some_and(|owner| owner != me) {
                state = lock
                    .released
                    .wait(state)
                    .unwrap_or_else(|poison| poison.into_inner());
            }
            state.1 += 1;
            let outermost = state.0.is_none();
            state.0 = Some(me);
            outermost
        };
        let guard = LeaseGuard { lock: lock.clone() };
        if outermost {
            let file = OpenOptions::new()
                .read(true)
                .append(true)
                .create(true)
                .open(&self.lock_path)?;
            file.lock()?;
            lock.state
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .2 = Some(file);
        }
        let result = work();
        drop(guard);
        result
    }

    fn load_unlocked(&self) -> Result<BTreeMap<String, SnapshotLease>> {
        if fs::metadata(&self.path).is_err() {
            return Ok(BTreeMap::new());
        }
        let corrupt =
            |detail: String| validation(format!("snapshot lease store is corrupt: {detail}"));
        let bytes = fs::read(&self.path).map_err(|error| corrupt(error.to_string()))?;
        let text = pystr::universal_newlines(pystr::decode_utf8(&bytes)?);
        let payload = json::parse(&text).ok_or_else(|| corrupt("Expecting value".to_string()))?;
        let Value::Dict(payload) = payload else {
            return Err(Error::new(
                ErrorKind::Attribute,
                format!(
                    "'{}' object has no attribute 'get'",
                    pystr::type_name(&payload)
                ),
            ));
        };
        if !payload
            .get("schema_version")
            .is_some_and(|value| json::py_eq(value, &Value::Int(LEASE_SCHEMA_VERSION)))
        {
            return Err(validation("snapshot lease schema is unsupported"));
        }
        if !payload
            .get("project_id")
            .is_some_and(|value| value.is_str(&self.project_id))
        {
            return Err(validation(
                "snapshot lease store belongs to another project",
            ));
        }
        let mut result = BTreeMap::new();
        let raws = match payload.get("leases") {
            None => Vec::new(),
            Some(Value::List(items)) => items.clone(),
            Some(other) => {
                return Err(Error::new(
                    ErrorKind::Type,
                    format!("'{}' object is not iterable", pystr::type_name(other)),
                ));
            }
        };
        for raw in raws {
            let Value::Dict(raw) = raw else {
                return Err(Error::new(
                    ErrorKind::Type,
                    "string indices must be integers, not 'str'",
                ));
            };
            let field = |key: &str| index_str(&raw, key);
            let instant = |key: &str| -> Result<Instant> { parse_instant(&field(key)?) };
            let attachment_paths = match raw.get("attachment_paths") {
                None => Vec::new(),
                Some(Value::List(items)) => items.iter().map(Value::py_str).collect(),
                Some(other) => {
                    return Err(Error::new(
                        ErrorKind::Type,
                        format!("'{}' object is not iterable", pystr::type_name(other)),
                    ));
                }
            };
            let lease = SnapshotLease {
                lease_id: field("lease_id")?,
                project_id: field("project_id")?,
                ticket_id: field("ticket_id")?,
                artifact_id: field("artifact_id")?,
                artifact_head: field("artifact_head")?,
                run_id: field("run_id")?,
                role: field("role")?,
                provider: field("provider")?,
                attachment_paths,
                created_at: instant("created_at")?,
                heartbeat_at: instant("heartbeat_at")?,
                state: raw
                    .get("state")
                    .map_or_else(|| "active".to_string(), Value::py_str),
                released_at: match raw.truthy("released_at") {
                    Some(value) => Some(parse_instant(&value.py_str())?),
                    None => None,
                },
                terminal_reason: raw.present("terminal_reason").map(Value::py_str),
            };
            if lease.project_id != self.project_id || result.contains_key(&lease.lease_id) {
                return Err(validation(
                    "snapshot lease identity is invalid or duplicated",
                ));
            }
            result.insert(lease.lease_id.clone(), lease);
        }
        Ok(result)
    }

    fn write_unlocked(&self, leases: &BTreeMap<String, SnapshotLease>) -> Result<()> {
        let mut payload = Dict::new();
        payload.insert("schema_version", LEASE_SCHEMA_VERSION);
        payload.insert("project_id", self.project_id.as_str());
        payload.insert(
            "leases",
            Value::List(
                leases
                    .values()
                    .map(|lease| Value::Dict(lease_json(lease)))
                    .collect(),
            ),
        );
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = temporary_beside(&self.path);
        fs::write(&temporary, canonical_json(&Value::Dict(payload)) + "\n")?;
        fs::rename(&temporary, &self.path)?;
        Ok(())
    }
}

// -- the retention manager -------------------------------------------------------

/// The archive catalog: entries by artifact ID, in file order.
type Catalog = Dict;

fn catalog_entry_of<'c>(catalog: &'c Catalog, artifact_id: &str) -> Option<&'c Dict> {
    catalog.get(artifact_id).and_then(Value::as_dict)
}

fn catalog_entries(catalog: &Catalog) -> impl Iterator<Item = (&str, &Dict)> {
    catalog
        .iter()
        .filter_map(|(key, value)| value.as_dict().map(|entry| (key, entry)))
}

/// `_catalog_from_files`' parse of `.orchestrator/archive-index.jsonl`.
fn parse_catalog(content: &[u8]) -> Result<Catalog> {
    let text = pystr::decode_utf8(content)?;
    let mut result = Catalog::new();
    for (index, line) in pystr::splitlines(text).into_iter().enumerate() {
        let line_number = index + 1;
        if pystr::strip(line).is_empty() {
            continue;
        }
        let value = json::parse(line).ok_or_else(|| Error::value("Expecting value"))?;
        let Value::Dict(value) = value else {
            return Err(Error::new(
                ErrorKind::Attribute,
                format!(
                    "'{}' object has no attribute 'get'",
                    pystr::type_name(&value)
                ),
            ));
        };
        if !value
            .get("schema_version")
            .is_some_and(|version| json::py_eq(version, &Value::Int(CATALOG_SCHEMA_VERSION)))
        {
            return Err(validation(format!(
                "archive catalog line {line_number} has unsupported schema"
            )));
        }
        let artifact_id = match value.get("artifact_id") {
            Some(Value::Str(artifact_id)) if result.get(artifact_id).is_none() => {
                artifact_id.clone()
            }
            _ => {
                return Err(validation(
                    "archive catalog has invalid or duplicate artifact identity",
                ));
            }
        };
        result.insert(&artifact_id, Value::Dict(value));
    }
    Ok(result)
}

/// `_encode_catalog`.
fn encode_catalog(catalog: &Catalog) -> Vec<u8> {
    let mut keys: Vec<&str> = catalog.iter().map(|(key, _)| key).collect();
    keys.sort_unstable();
    let mut text = String::new();
    for key in keys {
        if let Some(value) = catalog.get(key) {
            text.push_str(&canonical_json(value));
            text.push('\n');
        }
    }
    text.into_bytes()
}

/// `_card`.
fn card(entry: &Dict) -> Result<HistoricalCard> {
    let attachments = entry
        .get("attachments")
        .and_then(Value::as_list)
        .unwrap_or_default();
    let mut attachment_bytes = 0;
    for item in attachments {
        let size = match item.as_dict() {
            Some(item) => item.get("size").cloned().unwrap_or(Value::Int(0)),
            None => {
                return Err(Error::new(
                    ErrorKind::Attribute,
                    format!("'{}' object has no attribute 'get'", pystr::type_name(item)),
                ));
            }
        };
        attachment_bytes += size.py_int().ok_or_else(|| {
            Error::value(format!(
                "invalid literal for int() with base 10: {}",
                pystr::repr(&size.py_str())
            ))
        })?;
    }
    Ok(HistoricalCard {
        artifact_id: index_str(entry, "artifact_id")?,
        ticket_id: index_str(entry, "ticket_id")?,
        title: index_str(entry, "title")?,
        status: index_str(entry, "status")?,
        activity_at: parse_instant(&index_str(entry, "activity_at")?)?,
        state: RetentionState::from_value(&index_str(entry, "state")?)?,
        attachment_count: attachments.len() as i64,
        attachment_bytes,
    })
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

/// `ArtifactRetentionManager`: plans and commits retention without creating
/// another ticket authority.
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

impl EventArgs {
    fn actor(&self, default: &str) -> String {
        self.actor_type
            .clone()
            .unwrap_or_else(|| default.to_string())
    }
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

/// Archive catalog entries already verified per project, as (catalog
/// digest, head, artifact IDs). Every retention sweep previews the whole
/// catalog, and verifying each entry spawns about six git processes (RR-449).
/// Git objects are immutable and the artifact history only grows, so an
/// entry verified at one head stays verified for the same catalog bytes at
/// any descendant head.
type VerifiedCatalog = (String, String, HashSet<String>);

static VERIFIED_CATALOGS: LazyLock<Mutex<HashMap<(PathBuf, PathBuf), VerifiedCatalog>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn verified_catalog_key(store: &ArtifactStore) -> (PathBuf, PathBuf) {
    (store.repo_path.clone(), store.project_state.clone())
}

fn entry_map(entries: &Entries) -> HashMap<&str, &TreeEntry> {
    entries
        .iter()
        .map(|(path, entry)| (path.as_str(), entry))
        .collect()
}

impl<'s> ArtifactRetentionManager<'s> {
    pub fn new(store: &'s ArtifactStore, options: RetentionOptions<'s>) -> Result<Self> {
        if !["local_only", "enabled", "paused"].contains(&options.remote_mode.as_str()) {
            return Err(validation(format!(
                "invalid retention remote mode: {}",
                pystr::repr(&options.remote_mode)
            )));
        }
        Ok(Self {
            store,
            lease_store: options
                .lease_store
                .unwrap_or_else(|| SnapshotLeaseStore::new(store)),
            remote_mode: options.remote_mode,
            remote_confirmation: options.remote_confirmation,
            synchronizer: options.synchronizer,
            enabled: options.enabled,
            transaction_path: store.project_state.join("retention-transaction.json"),
            now: options.now.unwrap_or_else(|| Box::new(Instant::now)),
            failure_injector: options.failure_injector,
        })
    }

    fn now(&self) -> Instant {
        (self.now)()
    }

    pub fn preview(&self, evaluated_at: Option<Instant>) -> Result<RetentionPlan> {
        let instant = evaluated_at.unwrap_or_else(|| self.now());
        let snapshot = self.store.snapshot()?;
        let leased: HashSet<String> = self.lease_store.active_ticket_ids()?.into_iter().collect();
        self.preview_head(&snapshot.commit_id, &snapshot.files, instant, &leased, true)
    }

    fn preview_head(
        &self,
        head: &str,
        files: &[(String, Vec<u8>)],
        evaluated_at: Instant,
        leased: &HashSet<String>,
        include_transaction: bool,
    ) -> Result<RetentionPlan> {
        let entries = self.store.tree_entries(Some(head))?;
        let entries = entry_map(&entries);
        let files: BTreeMap<&str, &[u8]> = files
            .iter()
            .map(|(path, content)| (path.as_str(), content.as_slice()))
            .collect();
        let transaction = if include_transaction {
            self.read_transaction()?
        } else {
            None
        };
        let transaction_ids: HashSet<String> = transaction
            .as_ref()
            .and_then(|transaction| transaction.get("ticket_ids"))
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .filter_map(|value| value.as_str().map(str::to_string))
            .collect();
        let paths: Vec<&str> = files.keys().copied().collect();
        let mut canonical: Vec<RetentionTicket> = Vec::new();
        for (path, content) in &files {
            if !is_ticket_path(path) {
                continue;
            }
            let ticket_id = posix_stem(path);
            let blob_id = entries
                .get(path)
                .map(|entry| entry.oid.clone())
                .ok_or_else(|| key_error(path))?;
            let mut ticket =
                self.retention_ticket(head, ticket_id, path, content, &blob_id, &paths, leased)?;
            if transaction_ids.contains(ticket_id) {
                let mut reasons: BTreeSet<String> = ticket.exemptions.iter().cloned().collect();
                reasons.insert("in_flight_transaction".to_string());
                if transaction
                    .as_ref()
                    .is_some_and(|transaction| transaction.truthy("last_error").is_some())
                {
                    reasons.insert("retryable_verification_failure".to_string());
                }
                ticket.exemptions = reasons.into_iter().collect();
            }
            if canonical
                .iter()
                .any(|existing| existing.artifact_id == ticket.artifact_id)
            {
                return Err(validation(format!(
                    "duplicate immutable artifact_id in materialized tickets: {}",
                    ticket.artifact_id
                )));
            }
            canonical.push(ticket);
        }

        let catalog_content = files.get(CATALOG_PATH).copied().unwrap_or_default();
        let catalog = parse_catalog(catalog_content)?;
        let catalog_digest = hex_digest(catalog_content);
        let already_verified = self.catalog_entries_verified_at(head, &catalog_digest)?;
        let mut verified: HashSet<String> = HashSet::new();
        for (artifact_id, entry) in catalog_entries(&catalog) {
            if canonical
                .iter()
                .any(|ticket| ticket.artifact_id == artifact_id)
                || entry
                    .get("state")
                    .is_some_and(|state| state.is_str(RetentionState::DeletedTombstone.value()))
            {
                continue;
            }
            let ticket_id = match entry.truthy("ticket_id") {
                Some(value) => value.py_str(),
                None => artifact_id.to_string(),
            };
            let checked = self.catalog_ticket(entry).and_then(|ticket| {
                if !already_verified.contains(artifact_id) {
                    self.verified_catalog_entry(head, &catalog, entry, None)?;
                }
                Ok(ticket)
            });
            let ticket = match checked {
                Ok(ticket) => ticket,
                Err(error) if is_missing_historical_object(&error) => {
                    return Err(validation(format!(
                        "archive catalog integrity blocker for {ticket_id}: required historical objects are unavailable"
                    )));
                }
                Err(error) if is_validation_or_semantic(&error) => {
                    return Err(validation(format!(
                        "archive catalog integrity blocker for {ticket_id}: {error}"
                    )));
                }
                Err(error) => return Err(error),
            };
            if canonical
                .iter()
                .any(|existing| existing.ticket_id == ticket.ticket_id)
            {
                return Err(validation(format!(
                    "ticket {} has conflicting materialized and catalog identities",
                    ticket.ticket_id
                )));
            }
            canonical.push(ticket);
            verified.insert(artifact_id.to_string());
        }
        VERIFIED_CATALOGS
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .insert(
                verified_catalog_key(self.store),
                (catalog_digest, head.to_string(), verified),
            );

        let (mut terminal, mut nonterminal): (Vec<RetentionTicket>, Vec<RetentionTicket>) =
            canonical
                .into_iter()
                .partition(|ticket| is_terminal(&ticket.status));
        // Python's sort is stable: the immutable identity first and canonical
        // activity second gives descending activity with ascending
        // artifact_id ties, independent of display ID or provider.
        terminal.sort_by(|left, right| left.artifact_id.cmp(&right.artifact_id));
        terminal.sort_by(|left, right| right.activity_at.cmp(&left.activity_at));
        let retained_terminal: Vec<RetentionTicket> = terminal
            .iter()
            .take(TERMINAL_RETENTION_LIMIT)
            .cloned()
            .collect();
        let retained_ids: HashSet<&str> = retained_terminal
            .iter()
            .map(|ticket| ticket.artifact_id.as_str())
            .collect();
        let older_materialized: Vec<&RetentionTicket> = terminal
            .iter()
            .filter(|ticket| {
                ticket.materialized && !retained_ids.contains(ticket.artifact_id.as_str())
            })
            .collect();
        let exempt: Vec<RetentionTicket> = older_materialized
            .iter()
            .filter(|ticket| !ticket.exemptions.is_empty())
            .map(|ticket| (*ticket).clone())
            .collect();
        let candidates: Vec<RetentionTicket> = older_materialized
            .iter()
            .filter(|ticket| ticket.exemptions.is_empty())
            .map(|ticket| (*ticket).clone())
            .collect();
        let mut materialize: Vec<RetentionTicket> = nonterminal
            .iter()
            .chain(retained_terminal.iter())
            .filter(|ticket| !ticket.materialized)
            .cloned()
            .collect();
        nonterminal.sort_by(|left, right| left.ticket_id.cmp(&right.ticket_id));
        materialize.sort_by(|left, right| left.ticket_id.cmp(&right.ticket_id));
        Ok(RetentionPlan {
            schema_version: RETENTION_PLAN_SCHEMA_VERSION,
            policy: RETENTION_POLICY.to_string(),
            limit: TERMINAL_RETENTION_LIMIT,
            project_id: self.store.project_id.clone(),
            artifact_head: head.to_string(),
            evaluated_at,
            candidates,
            retained_terminal,
            nonterminal,
            materialize,
            exempt,
            ranked_terminal: terminal,
        })
    }

    pub fn archive(
        &self,
        plan: &RetentionPlan,
        event: &EventArgs,
        synchronizer: Option<&ArtifactSyncEngine<'_>>,
    ) -> Result<ArchiveResult> {
        self.require_enabled()?;
        if plan.project_id != self.store.project_id {
            return Err(validation("retention plan belongs to another project"));
        }
        let synchronizer = synchronizer.or(self.synchronizer);
        let actor_type = event.actor("system");
        if let Some(existing) = self.read_transaction()? {
            if !existing
                .get("event_id")
                .is_some_and(|value| value.is_str(&event.event_id))
            {
                return Err(concurrent(
                    "another retention publication transaction must be recovered first",
                ));
            }
            self.validate_remote_transaction(
                synchronizer,
                Some(&self.transaction_confirmation(&existing)?),
            )?;
            return self.lease_store.with_lock(|| {
                self.store
                    .with_writer_lock(|| self.resume_archive(existing, synchronizer))
            });
        }
        if let Some((commit_id, _)) = self.store.find_event(&event.event_id)? {
            return Ok(ArchiveResult::new(
                RetentionState::Archived,
                Some(prior_result(self.store, &event.event_id, &commit_id)?),
                plan.candidate_ids(),
            ));
        }
        if plan.candidates.is_empty() {
            return Ok(ArchiveResult::new(
                RetentionState::Archived,
                None,
                Vec::new(),
            ));
        }
        let confirmation = self.validate_remote_transaction(synchronizer, None)?;
        let synchronizer = synchronizer.expect("validated above");
        self.lease_store.with_lock(|| {
            self.store.with_writer_lock(|| {
                let current = self.store.head()?;
                if current.as_deref() != Some(plan.artifact_head.as_str()) {
                    return Err(concurrent("artifact head changed since retention preview"));
                }
                let current = plan.artifact_head.clone();
                let refreshed = self.preview(Some(plan.evaluated_at))?;
                if plan_identity(&refreshed) != plan_identity(plan) {
                    return Err(concurrent("retention eligibility changed since preview"));
                }
                let preflight = synchronizer.sync_confirmed(
                    &confirmation.remote_url_sha256,
                    &confirmation.push_url_sha256,
                )?;
                if preflight.state != SyncState::Clean {
                    return Ok(ArchiveResult::pending(
                        refreshed.candidate_ids(),
                        preflight.recovery.clone().filter(|text| !text.is_empty()).unwrap_or_else(
                            || "Reconcile the selected GitHub artifact ref and retry.".to_string(),
                        ),
                    ));
                }
                if preflight.local_head.as_deref() != Some(current.as_str())
                    || preflight.remote_head.as_deref() != Some(current.as_str())
                    || self.store.head()?.as_deref() != Some(current.as_str())
                {
                    return Ok(ArchiveResult::pending(
                        refreshed.candidate_ids(),
                        "Artifact synchronization changed the canonical head; preview the terminal candidates again before deletion.".to_string(),
                    ));
                }
                let entries = self.store.tree_entries(Some(&current))?;
                let mut catalog = self.catalog(&current)?;
                for ticket in &refreshed.candidates {
                    self.verify_active_ticket(ticket, &entries)?;
                    let entry = self.catalog_entry(ticket, &entries, plan.evaluated_at)?;
                    catalog.insert(&ticket.artifact_id, Value::Dict(entry));
                }
                let mut operations = vec![Operation::ArchiveIndexWrite {
                    content: encode_catalog(&catalog),
                }];
                operations.extend(refreshed.candidates.iter().map(|ticket| {
                    Operation::TicketDelete {
                        ticket_id: ticket.ticket_id.clone(),
                    }
                }));
                self.inject("before_archive_commit")?;
                let write = self.store.prepare_mutation(&Mutation {
                    event_id: event.event_id.clone(),
                    actor_type: actor_type.clone(),
                    device_id: event.device_id.clone(),
                    operations,
                    expected_base: Some(current.clone()),
                    provider: event.provider.clone(),
                    summary: format!("Archive {} Relay ticket(s)", refreshed.candidates.len()),
                })?;
                self.verify_archived_reachability(&write.commit_id, &refreshed.candidates, &catalog)?;
                let candidate_entries = self.store.tree_entries(Some(&write.commit_id))?;
                let proofs = self.archive_proofs(
                    &write.commit_id,
                    &refreshed.candidates,
                    &entries,
                    &candidate_entries,
                )?;
                let mut transaction = Dict::new();
                transaction.insert("schema_version", RETENTION_TRANSACTION_SCHEMA_VERSION);
                transaction.insert("project_id", self.store.project_id.as_str());
                transaction.insert("event_id", event.event_id.as_str());
                transaction.insert("device_id", event.device_id.as_str());
                transaction.insert("actor_type", actor_type.as_str());
                transaction.insert(
                    "provider",
                    event.provider.as_deref().map_or(Value::Null, Value::from),
                );
                transaction.insert("phase", "prepared");
                transaction.insert("base_head", current.as_str());
                transaction.insert("candidate_head", write.commit_id.as_str());
                transaction.insert("scratch_ref", self.scratch_ref(&event.event_id));
                transaction.insert("ticket_ids", strings(&refreshed.candidate_ids()));
                transaction.insert(
                    "proofs",
                    Value::List(proofs.iter().map(|proof| Value::Dict(proof_dict(proof))).collect()),
                );
                transaction.insert("remote_confirmation", Value::Dict(confirmation.as_dict()));
                transaction.insert("last_error", Value::Null);
                self.publish_transaction_scratch(&transaction)?;
                self.inject("after_archive_scratch")?;
                self.write_transaction(&transaction)?;
                self.inject("after_archive_prepare")?;
                self.resume_archive(transaction, Some(synchronizer))
            })
        })
    }

    /// Resume an interrupted publication transaction without a stale plan.
    pub fn recover_archive(
        &self,
        synchronizer: Option<&ArtifactSyncEngine<'_>>,
    ) -> Result<Option<ArchiveResult>> {
        self.require_enabled()?;
        let Some(transaction) = self.read_transaction()? else {
            return Ok(None);
        };
        let synchronizer = synchronizer.or(self.synchronizer);
        self.validate_remote_transaction(
            synchronizer,
            Some(&self.transaction_confirmation(&transaction)?),
        )?;
        self.lease_store
            .with_lock(|| {
                self.store
                    .with_writer_lock(|| self.resume_archive(transaction, synchronizer))
            })
            .map(Some)
    }

    /// Restore a compliant projection from only the confirmed artifact ref.
    pub fn recover_from_remote(
        &self,
        synchronizer: Option<&ArtifactSyncEngine<'_>>,
    ) -> Result<SyncResult> {
        self.require_enabled()?;
        let synchronizer = synchronizer.or(self.synchronizer);
        let confirmation = self.validate_remote_transaction(synchronizer, None)?;
        let synchronizer = synchronizer.expect("validated above");
        let validate = |head: &str| -> Result<()> {
            self.store.validate_artifact_head(head)?;
            let entries = self.store.tree_entries(Some(head))?;
            let mut files = Vec::with_capacity(entries.len());
            for (path, entry) in &entries {
                files.push((path.clone(), self.store.cat_blob(&entry.oid)?));
            }
            let plan = self.preview_head(head, &files, self.now(), &HashSet::new(), false)?;
            let materialized: BTreeSet<&str> = files
                .iter()
                .filter(|(path, _)| is_ticket_path(path))
                .map(|(path, _)| posix_stem(path))
                .collect();
            let nonterminal = plan.nonterminal_ids();
            let retained = plan.retained_terminal_ids();
            let expected: BTreeSet<&str> = nonterminal
                .iter()
                .chain(retained.iter())
                .map(String::as_str)
                .collect();
            if !plan.candidates.is_empty()
                || !plan.materialize.is_empty()
                || materialized != expected
            {
                return Err(validation(
                    "remote artifact ref does not materialize every nonterminal ticket and the newest 25 terminal tickets",
                ));
            }
            Ok(())
        };
        synchronizer.recover_exact_ref(&confirmation.remote_url_sha256, Some(&validate))
    }

    pub fn historical_search(&self, query: &str) -> Result<Vec<HistoricalCard>> {
        let catalog = self.catalog(&self.head_required()?)?;
        let needle = pystr::strip(&casefold(query)).to_string();
        let mut cards = Vec::new();
        for (_, entry) in catalog_entries(&catalog) {
            let archived = entry.get("state").is_some_and(|state| {
                state.is_str(RetentionState::Archived.value())
                    || state.is_str(RetentionState::DeletedTombstone.value())
            });
            if !archived {
                continue;
            }
            let haystack = casefold(&format!(
                "{} {}",
                get_str(entry, "ticket_id", ""),
                get_str(entry, "title", "")
            ));
            if !needle.is_empty() && !haystack.contains(&needle) {
                continue;
            }
            cards.push(card(entry)?);
        }
        cards.sort_by(|left, right| {
            (right.activity_at, &right.artifact_id).cmp(&(left.activity_at, &left.artifact_id))
        });
        Ok(cards)
    }

    pub fn historical_detail(
        &self,
        artifact_id: &str,
        access: HistoryAccess<'_>,
    ) -> Result<HistoricalDetail> {
        let artifact_head = self.head_required()?;
        let catalog = self.catalog(&artifact_head)?;
        let Some(entry) = catalog_entry_of(&catalog, artifact_id) else {
            return Ok(HistoricalDetail::unavailable(
                HistoryAvailability::NotFound,
                None,
                None,
            ));
        };
        let described = self
            .catalog_attachment_metadata(&catalog, entry)
            .and_then(|attachments| Ok((attachments, card(entry)?)));
        let (attachments, card) = match described {
            Ok(value) => value,
            Err(error) if is_validation_or_semantic(&error) => {
                return Ok(HistoricalDetail::unavailable(
                    HistoryAvailability::Tampered,
                    None,
                    Some(error.message),
                ));
            }
            Err(error) => return Err(error),
        };
        let source_commit = get_str(entry, "source_commit", "");
        if !self.object_exists(&source_commit)? {
            match access.deepen.filter(|_| access.online) {
                None => {
                    return Ok(HistoricalDetail::unavailable(
                        HistoryAvailability::NeedsNetwork,
                        Some(card),
                        Some(
                            "Connect and explicitly deepen the configured artifact ref."
                                .to_string(),
                        ),
                    ));
                }
                Some(deepen) => deepen(&source_commit)?,
            }
        }
        match self.verified_catalog_entry(&artifact_head, &catalog, entry, Some(&attachments)) {
            Ok(ticket_bytes) => Ok(HistoricalDetail {
                availability: HistoryAvailability::Available,
                card: Some(card),
                ticket_bytes: Some(ticket_bytes),
                attachments,
                recovery: None,
            }),
            Err(error) if is_missing_historical_object(&error) => Ok(HistoricalDetail::unavailable(
                HistoryAvailability::NeedsNetwork,
                Some(card),
                Some(
                    "Required historical objects are unavailable; explicitly deepen while online."
                        .to_string(),
                ),
            )),
            Err(error) if is_validation_or_semantic(&error) => Ok(HistoricalDetail::unavailable(
                HistoryAvailability::Tampered,
                Some(card),
                Some(error.message),
            )),
            Err(error) => Err(error),
        }
    }

    /// One verified archive attachment, without materializing its ticket.
    pub fn historical_attachment(
        &self,
        artifact_id: &str,
        filename: &str,
        access: HistoryAccess<'_>,
    ) -> Result<HistoricalAttachment> {
        validate_safe_id(artifact_id, "artifact ID")?;
        if posix_name(filename) != filename {
            return Err(validation(format!(
                "invalid attachment filename: {}",
                pystr::repr(filename)
            )));
        }
        // Reuse the store's ownership/type policy instead of accepting an
        // archive-catalog MIME declaration on trust.
        let mime_type = store::attachment_mime_for_filename(filename)?;
        let artifact_head = self.head_required()?;
        let detail = self.historical_detail(artifact_id, access)?;
        let card = match (&detail.availability, &detail.card) {
            (HistoryAvailability::Available, Some(card)) => card.clone(),
            _ => {
                return Err(validation(
                    detail
                        .recovery
                        .clone()
                        .filter(|text| !text.is_empty())
                        .unwrap_or_else(|| "historical ticket is unavailable".to_string()),
                ));
            }
        };
        if self.store.head()?.as_deref() != Some(artifact_head.as_str()) {
            return Err(concurrent(
                "artifact head changed while verifying historical attachment",
            ));
        }
        let expected_path = format!(".orchestrator/attachments/{}/{filename}", card.ticket_id);
        let matches: Vec<&Dict> = detail
            .attachments
            .iter()
            .filter(|item| {
                item.get("path")
                    .is_some_and(|path| path.is_str(&expected_path))
            })
            .collect();
        if matches.len() != 1 {
            return Err(validation(format!(
                "historical attachment {} was not found",
                pystr::repr(filename)
            )));
        }
        let item = matches[0];
        if !item
            .get("mime_type")
            .is_some_and(|value| value.is_str(mime_type))
        {
            return Err(validation(
                "historical attachment MIME metadata is inconsistent",
            ));
        }
        let catalog = self.catalog(&artifact_head)?;
        let source_commit = catalog_entry_of(&catalog, artifact_id)
            .ok_or_else(|| key_error(artifact_id))
            .and_then(|entry| index_str(entry, "source_commit"))?;
        let blob = get_str(item, "blob", "");
        let content = self.verified_historical_blob(&source_commit, &expected_path, &blob)?;
        self.store
            .validate_content_for_path(&expected_path, &content)?;
        let size = item.get("size").cloned().unwrap_or(Value::Int(-1));
        let size = size.py_int().ok_or_else(|| {
            Error::value(format!(
                "invalid literal for int() with base 10: {}",
                pystr::repr(&size.py_str())
            ))
        })?;
        if size != content.len() as i64 {
            return Err(validation(
                "historical attachment size metadata is inconsistent",
            ));
        }
        Ok(HistoricalAttachment {
            artifact_id: artifact_id.to_string(),
            ticket_id: card.ticket_id,
            filename: filename.to_string(),
            mime_type: mime_type.to_string(),
            content,
            blob_id: index_str(item, "blob")?,
        })
    }

    pub fn restore(
        &self,
        artifact_id: &str,
        event: &EventArgs,
        access: HistoryAccess<'_>,
    ) -> Result<ArchiveResult> {
        self.reinstate(artifact_id, event, access, false)
    }

    /// Make archived terminal work nonterminal and therefore uncapped.
    pub fn reopen(
        &self,
        artifact_id: &str,
        event: &EventArgs,
        access: HistoryAccess<'_>,
    ) -> Result<ArchiveResult> {
        self.reinstate(artifact_id, event, access, true)
    }

    /// `restore` and `reopen`, which differ only in what they write.
    fn reinstate(
        &self,
        artifact_id: &str,
        event: &EventArgs,
        access: HistoryAccess<'_>,
        reopen: bool,
    ) -> Result<ArchiveResult> {
        self.require_enabled()?;
        let local_state = if reopen {
            RetentionState::MaterializedExempt
        } else {
            RetentionState::MaterializedRecent
        };
        let state = if self.remote_mode == "enabled" {
            RetentionState::RestorePendingSync
        } else {
            local_state
        };
        if let Some((commit_id, _)) = self.store.find_event(&event.event_id)? {
            let ticket_id = self.materialized_ticket_id(artifact_id)?;
            return Ok(ArchiveResult::new(
                state,
                Some(prior_result(self.store, &event.event_id, &commit_id)?),
                ticket_id.into_iter().collect(),
            ));
        }
        let head = self.head_required()?;
        let mut catalog = self.catalog(&head)?;
        let entry = catalog_entry_of(&catalog, artifact_id)
            .filter(|entry| {
                entry.get("state").is_some_and(|state| {
                    state.is_str(RetentionState::Archived.value())
                        || state.is_str(RetentionState::DeletedTombstone.value())
                })
            })
            .cloned()
            .ok_or_else(|| {
                validation(format!(
                    "artifact {} is not archived",
                    pystr::repr(artifact_id)
                ))
            })?;
        let detail = self.historical_detail(artifact_id, access)?;
        let ticket_bytes = match (&detail.availability, &detail.ticket_bytes) {
            (HistoryAvailability::Available, Some(bytes)) => bytes.clone(),
            _ => {
                return Err(validation(
                    detail
                        .recovery
                        .clone()
                        .filter(|text| !text.is_empty())
                        .unwrap_or_else(|| "historical ticket is unavailable".to_string()),
                ));
            }
        };
        if self.store.head()?.as_deref() != Some(head.as_str()) {
            return Err(concurrent(if reopen {
                "artifact head changed while verifying historical reopen"
            } else {
                "artifact head changed while verifying historical restore"
            }));
        }
        let instant = format_instant(event.at.unwrap_or_else(|| self.now()));
        let ticket_id = index_str(&entry, "ticket_id")?;
        let markdown = if reopen {
            let mut markdown = ticket_bytes;
            for (key, value) in [
                ("status", "backlog"),
                ("canceled", "false"),
                ("run_id", "null"),
                ("run_state", "none"),
                ("reopened_at", instant.as_str()),
                ("activity_at", instant.as_str()),
            ] {
                markdown = set_front_matter_value(&markdown, key, value)?;
            }
            markdown
        } else {
            set_front_matter_value(&ticket_bytes, "activity_at", &instant)?
        };
        let mut operations = vec![Operation::TicketWrite {
            ticket_id: ticket_id.clone(),
            artifact_id: artifact_id.to_string(),
            markdown,
        }];
        let source_commit = index_str(&entry, "source_commit")?;
        for attachment in &detail.attachments {
            let path = index_str(attachment, "path")?;
            let content = self.verified_historical_blob(
                &source_commit,
                &path,
                &index_str(attachment, "blob")?,
            )?;
            operations.push(Operation::AttachmentWrite {
                ticket_id: ticket_id.clone(),
                filename: posix_name(&path).to_string(),
                mime_type: index_str(attachment, "mime_type")?,
                content,
            });
        }
        let mut updated = entry.clone();
        updated.insert("state", local_state.value());
        if reopen {
            updated.insert("status", "backlog");
            updated.insert("activity_at", instant.as_str());
        }
        updated.insert("restored_at", instant.as_str());
        catalog.insert(artifact_id, Value::Dict(updated));
        operations.push(Operation::ArchiveIndexWrite {
            content: encode_catalog(&catalog),
        });
        let write = self.store.mutate(&Mutation {
            event_id: event.event_id.clone(),
            actor_type: event.actor("user"),
            device_id: event.device_id.clone(),
            operations,
            expected_base: Some(head),
            provider: event.provider.clone(),
            summary: format!(
                "{} Relay ticket {ticket_id}",
                if reopen { "Reopen" } else { "Restore" }
            ),
        })?;
        Ok(ArchiveResult::new(state, Some(write), vec![ticket_id]))
    }

    pub fn delete(&self, ticket_id: &str, event: &EventArgs) -> Result<ArchiveResult> {
        self.require_enabled()?;
        let instant = event.at.unwrap_or_else(|| self.now());
        let head = self.head_required()?;
        let snapshot = self.store.snapshot()?;
        let path = format!(".orchestrator/{ticket_id}.md");
        let content = snapshot
            .file(&path)
            .ok_or_else(|| {
                validation(format!(
                    "ticket {} is not materialized",
                    pystr::repr(ticket_id)
                ))
            })?
            .to_vec();
        let entries = self.store.tree_entries(Some(&head))?;
        let blob_id = entry_map(&entries)
            .get(path.as_str())
            .map(|entry| entry.oid.clone())
            .ok_or_else(|| key_error(&path))?;
        let paths: Vec<&str> = snapshot
            .files
            .iter()
            .map(|(path, _)| path.as_str())
            .collect();
        let leased: HashSet<String> = self.lease_store.active_ticket_ids()?.into_iter().collect();
        let ticket =
            self.retention_ticket(&head, ticket_id, &path, &content, &blob_id, &paths, &leased)?;
        if !ticket.exemptions.is_empty() {
            return Err(validation(format!(
                "ticket {ticket_id} cannot be deleted while exempt: {}",
                ticket.exemptions.join(", ")
            )));
        }
        let mut catalog = self.catalog(&head)?;
        let mut entry = self.catalog_entry(&ticket, &entries, instant)?;
        entry.insert("state", RetentionState::DeletedTombstone.value());
        entry.insert("deleted_at", format_instant(instant));
        catalog.insert(&ticket.artifact_id, Value::Dict(entry));
        let write = self.store.mutate(&Mutation {
            event_id: event.event_id.clone(),
            actor_type: event.actor("user"),
            device_id: event.device_id.clone(),
            operations: vec![
                Operation::ArchiveIndexWrite {
                    content: encode_catalog(&catalog),
                },
                Operation::TicketDelete {
                    ticket_id: ticket_id.to_string(),
                },
            ],
            expected_base: Some(head),
            provider: event.provider.clone(),
            summary: format!("Recoverably delete Relay ticket {ticket_id}"),
        })?;
        Ok(ArchiveResult {
            warnings: vec![DELETE_WARNING.to_string()],
            ..ArchiveResult::new(
                RetentionState::DeletedTombstone,
                Some(write),
                vec![ticket_id.to_string()],
            )
        })
    }

    pub fn dependency_satisfied(
        &self,
        dependency_id: &str,
        snapshot: Option<&Snapshot>,
    ) -> Result<bool> {
        let owned;
        let snapshot = match snapshot {
            Some(snapshot) => snapshot,
            None => {
                owned = self.store.snapshot()?;
                &owned
            }
        };
        let path = format!(".orchestrator/{dependency_id}.md");
        if let Some(content) = snapshot.file(&path) {
            return Ok(canonical_status(&front_matter(content)?) == "done");
        }
        let catalog = self.catalog(&snapshot.commit_id)?;
        for (_, entry) in catalog_entries(&catalog) {
            if !entry
                .get("ticket_id")
                .is_some_and(|value| value.is_str(dependency_id))
            {
                continue;
            }
            if !entry
                .get("status")
                .is_some_and(|value| value.is_str("done"))
            {
                return Ok(false);
            }
            let detail = self
                .historical_detail(&get_str(entry, "artifact_id", ""), HistoryAccess::default())?;
            if detail.availability != HistoryAvailability::Available {
                return Err(dependency_history_unavailable(dependency_id, &detail));
            }
            return Ok(true);
        }
        Ok(false)
    }

    /// A dependency's verified execution mode, without restoring it.
    pub fn dependency_execution_mode(
        &self,
        dependency_id: &str,
        snapshot: Option<&Snapshot>,
    ) -> Result<Option<String>> {
        let owned;
        let snapshot = match snapshot {
            Some(snapshot) => snapshot,
            None => {
                owned = self.store.snapshot()?;
                &owned
            }
        };
        let execution_mode = |front: Front| {
            front_get(&front, "execution_mode")
                .unwrap_or("implementation")
                .to_string()
        };
        let path = format!(".orchestrator/{dependency_id}.md");
        if let Some(content) = snapshot.file(&path) {
            return Ok(Some(execution_mode(front_matter(content)?)));
        }
        let catalog = self.catalog(&snapshot.commit_id)?;
        for (_, entry) in catalog_entries(&catalog) {
            if !entry
                .get("ticket_id")
                .is_some_and(|value| value.is_str(dependency_id))
            {
                continue;
            }
            let detail = self
                .historical_detail(&get_str(entry, "artifact_id", ""), HistoryAccess::default())?;
            return match (&detail.availability, &detail.ticket_bytes) {
                (HistoryAvailability::Available, Some(bytes)) => {
                    Ok(Some(execution_mode(front_matter(bytes)?)))
                }
                _ => Err(dependency_history_unavailable(dependency_id, &detail)),
            };
        }
        Ok(None)
    }

    /// `transaction_status()`, as the JSON mapping Python returns.
    pub fn transaction_status(&self) -> Result<Dict> {
        let mut result = Dict::new();
        let Some(transaction) = self.read_transaction()? else {
            result.insert("state", "idle");
            result.insert("retry_available", false);
            return Ok(result);
        };
        result.insert(
            "state",
            match transaction.truthy("phase") {
                Some(phase) => phase.py_str(),
                None => "pending".to_string(),
            },
        );
        result.insert(
            "event_id",
            transaction.get("event_id").cloned().unwrap_or(Value::Null),
        );
        result.insert(
            "ticket_ids",
            Value::List(
                transaction
                    .truthy("ticket_ids")
                    .and_then(Value::as_list)
                    .unwrap_or_default()
                    .to_vec(),
            ),
        );
        result.insert(
            "last_error",
            transaction
                .get("last_error")
                .cloned()
                .unwrap_or(Value::Null),
        );
        result.insert("retry_available", true);
        Ok(result)
    }

    fn materialized_ticket_id(&self, artifact_id: &str) -> Result<Option<String>> {
        for (path, content) in &self.store.snapshot()?.files {
            if !is_ticket_path(path) {
                continue;
            }
            if front_get(&front_matter(content)?, "artifact_id") == Some(artifact_id) {
                return Ok(Some(posix_stem(path).to_string()));
            }
        }
        Ok(None)
    }

    pub fn storage_metrics(&self, paths: &StoragePaths) -> Result<StorageMetrics> {
        let root = &self.store.materialized_path;
        let materialized_files = if fs::metadata(root).is_ok() {
            regular_files(root)
        } else {
            Vec::new()
        };
        let materialized_bytes: i64 = materialized_files.iter().map(|path| file_size(path)).sum();
        let mut ticket_files = Vec::new();
        for path in &materialized_files {
            let is_md = path.extension().is_some_and(|extension| extension == "md")
                && path
                    .file_name()
                    .is_some_and(|name| !name.to_string_lossy().trim_start_matches('.').eq("md"));
            if path.parent() != Some(root.as_path()) || !is_md {
                continue;
            }
            let Ok(content) = fs::read(path) else {
                continue;
            };
            if front_matter(&content).ok().is_some_and(|front| {
                front_get(&front, "artifact_id").is_some_and(|id| !id.is_empty())
            }) {
                ticket_files.push(path.clone());
            }
        }
        let attachment_root = root.join("attachments");
        let attachment_files: Vec<&PathBuf> = materialized_files
            .iter()
            .filter(|path| path.starts_with(&attachment_root) && **path != attachment_root)
            .collect();
        let head = self.head_required()?;
        let listing = self
            .store
            .git(&["rev-list", "--objects", &head], &[], None, &[0])?
            .text();
        let mut seen: Vec<&str> = Vec::new();
        let mut unique: HashSet<&str> = HashSet::new();
        for line in pystr::splitlines(&listing) {
            let oid = line.split(' ').next().unwrap_or("");
            if !oid.is_empty() && unique.insert(oid) {
                seen.push(oid);
            }
        }
        let reachable = self.object_sizes(&seen)?;
        let sum = |paths: &[PathBuf]| -> i64 { paths.iter().map(|path| disk_usage(path)).sum() };
        let database_bytes = sum(&paths.database_paths);
        let run_log_bytes = sum(&paths.run_log_paths);
        let index_bytes = sum(&paths.index_paths);
        let cache_bytes = sum(&paths.cache_paths);
        let run_bytes = sum(&paths.run_paths) + database_bytes + run_log_bytes;
        let derived_bytes = sum(&paths.index_cache_paths) + index_bytes + cache_bytes;
        let catalog = self.catalog(&head)?;
        let plan = self.preview(None)?;
        // Reachable artifact history is not reclaimable without a separately
        // reviewed history rewrite. Derived indexes/caches are the only safely
        // reclaimable bytes represented by this view.
        Ok(StorageMetrics {
            materialized_worktree_bytes: materialized_bytes,
            materialized_file_count: materialized_files.len() as i64,
            materialized_ticket_bytes: ticket_files.iter().map(|path| file_size(path)).sum(),
            materialized_ticket_count: ticket_files.len() as i64,
            materialized_attachment_bytes: attachment_files
                .iter()
                .map(|path| file_size(path))
                .sum(),
            materialized_attachment_count: attachment_files.len() as i64,
            retained_terminal_count: plan.retained_terminal.len() as i64,
            nonterminal_count: plan.nonterminal.len() as i64,
            temporary_overage_count: plan.exempt.len() as i64,
            remotely_backed_history_count: catalog_entries(&catalog)
                .filter(|(_, entry)| {
                    entry
                        .get("state")
                        .is_some_and(|state| state.is_str(RetentionState::Archived.value()))
                })
                .count() as i64,
            reachable_git_object_bytes: reachable,
            database_bytes,
            run_log_bytes,
            index_bytes,
            cache_bytes,
            run_database_log_bytes: run_bytes,
            derived_index_cache_bytes: derived_bytes,
            reclaimable_estimate_bytes: derived_bytes,
        })
    }

    /// The summed `git cat-file -s` of each object, read through one
    /// `--batch-check` process rather than one process per object.
    fn object_sizes(&self, oids: &[&str]) -> Result<i64> {
        if oids.is_empty() {
            return Ok(0);
        }
        let input: String = oids.iter().map(|oid| format!("{oid}\n")).collect();
        let output = self
            .store
            .git(
                &["cat-file", "--batch-check=%(objectsize)"],
                &[],
                Some(input.as_bytes()),
                &[0],
            )?
            .text();
        let mut total = 0;
        for line in pystr::splitlines(&output) {
            let size = pystr::strip(line);
            total += size.parse::<i64>().map_err(|_| {
                Error::value(format!(
                    "invalid literal for int() with base 10: {}",
                    pystr::repr(size)
                ))
            })?;
        }
        Ok(total)
    }

    #[allow(clippy::too_many_arguments)]
    fn retention_ticket(
        &self,
        head: &str,
        ticket_id: &str,
        path: &str,
        content: &[u8],
        blob_id: &str,
        paths: &[&str],
        leased: &HashSet<String>,
    ) -> Result<RetentionTicket> {
        let front = front_matter(content)?;
        let artifact_id = front_get(&front, "artifact_id")
            .filter(|value| !value.is_empty())
            .ok_or_else(|| validation(format!("ticket {ticket_id} has no immutable artifact_id")))?
            .to_string();
        let mut activity_at: Option<Instant> = None;
        for field in ACTIVITY_FIELDS {
            if let Some(value) = front_get(&front, field).filter(|value| !value.is_empty()) {
                let instant = parse_instant(value)?;
                activity_at = Some(activity_at.map_or(instant, |latest| latest.max(instant)));
            }
        }
        let activity_at = activity_at.ok_or_else(|| {
            validation(format!(
                "ticket {ticket_id} has no durable activity timestamp; migration must anchor activity_at"
            ))
        })?;
        let status = canonical_status(&front);
        let mut dependencies = parse_list(front_get(&front, "depends_on").unwrap_or("[]"));
        dependencies.sort();
        let mut exemptions: BTreeSet<String> = BTreeSet::new();
        let run_state = front_get(&front, "run_state").unwrap_or("");
        if ACTIVE_RUN_STATES.contains(&run_state) {
            exemptions.insert(format!("live_lease:{run_state}"));
        }
        if parse_bool(front_get(&front, "pending_sync").unwrap_or("false"))
            || parse_bool(front_get(&front, "unpublished_conflict").unwrap_or("false"))
        {
            exemptions.insert("unpublished_content".to_string());
        }
        if !["", "none", "complete"].contains(&pystr::strip(
            front_get(&front, "retention_transaction").unwrap_or(""),
        )) {
            exemptions.insert("in_flight_transaction".to_string());
        }
        if parse_bool(front_get(&front, "retryable_verification_failure").unwrap_or("false")) {
            exemptions.insert("retryable_verification_failure".to_string());
        }
        if leased.contains(ticket_id) {
            exemptions.insert("live_lease:snapshot".to_string());
        }
        let attachment_prefix = format!(".orchestrator/attachments/{ticket_id}/");
        let mut attachment_paths: Vec<String> = paths
            .iter()
            .filter(|path| path.starts_with(&attachment_prefix))
            .map(|path| path.to_string())
            .collect();
        attachment_paths.sort();
        Ok(RetentionTicket {
            ticket_id: ticket_id.to_string(),
            artifact_id,
            title: front_get(&front, "title").unwrap_or(ticket_id).to_string(),
            status,
            activity_at,
            path: path.to_string(),
            blob_id: blob_id.to_string(),
            source_commit: head.to_string(),
            dependencies,
            attachment_paths,
            exemptions: exemptions.into_iter().collect(),
            materialized: true,
        })
    }

    fn catalog_ticket(&self, entry: &Dict) -> Result<RetentionTicket> {
        let missing: Vec<&str> = [
            "artifact_id",
            "ticket_id",
            "status",
            "activity_at",
            "ticket_path",
            "ticket_blob",
            "source_commit",
        ]
        .into_iter()
        .filter(|key| pystr::strip(&get_str(entry, key, "")).is_empty())
        .collect();
        if !missing.is_empty() {
            return Err(validation(format!(
                "archive catalog retention metadata is incomplete: {}",
                missing.join(", ")
            )));
        }
        let attachments: &[Value] = match entry.get("attachments") {
            None => &[],
            Some(Value::List(items)) if items.iter().all(|item| item.as_dict().is_some()) => items,
            Some(_) => return Err(validation("archive catalog attachments must be a list")),
        };
        let dependencies: &[Value] = match entry.get("dependencies") {
            None => &[],
            Some(Value::List(items)) => items,
            Some(_) => return Err(validation("archive catalog dependencies must be a list")),
        };
        let mut status = index_str(entry, "status")?;
        if !is_terminal(&status) {
            // Age-policy catalogs could record a canceled card's lane status
            // (for example, backlog) without its separate canceled flag. Read
            // the verified historical blob to migrate that ambiguity without
            // restoring the Markdown projection.
            let historical = self
                .verified_historical_blob(
                    &index_str(entry, "source_commit")?,
                    &index_str(entry, "ticket_path")?,
                    &index_str(entry, "ticket_blob")?,
                )
                .map_err(|error| {
                    if is_missing_historical_object(&error) {
                        validation(format!(
                            "archive catalog status for {} is ambiguous and its historical object is unavailable",
                            get_str(entry, "ticket_id", "")
                        ))
                    } else {
                        error
                    }
                })?;
            status = canonical_status(&front_matter(&historical)?);
        }
        let mut dependency_ids: Vec<String> = dependencies.iter().map(Value::py_str).collect();
        dependency_ids.sort();
        let mut attachment_paths: Vec<String> = attachments
            .iter()
            .filter_map(Value::as_dict)
            .map(|item| {
                item.get("path")
                    .map_or_else(|| "None".to_string(), Value::py_str)
            })
            .collect();
        attachment_paths.sort();
        Ok(RetentionTicket {
            ticket_id: index_str(entry, "ticket_id")?,
            artifact_id: index_str(entry, "artifact_id")?,
            title: match entry.truthy("title") {
                Some(title) => title.py_str(),
                None => index_str(entry, "ticket_id")?,
            },
            status,
            activity_at: parse_instant(&index_str(entry, "activity_at")?)?,
            path: index_str(entry, "ticket_path")?,
            blob_id: index_str(entry, "ticket_blob")?,
            source_commit: index_str(entry, "source_commit")?,
            dependencies: dependency_ids,
            attachment_paths,
            exemptions: Vec::new(),
            materialized: false,
        })
    }

    fn catalog_entry(
        &self,
        ticket: &RetentionTicket,
        entries: &Entries,
        archived_at: Instant,
    ) -> Result<Dict> {
        let entries = entry_map(entries);
        let mut attachments = Vec::new();
        for path in &ticket.attachment_paths {
            let entry = entries
                .get(path.as_str())
                .ok_or_else(|| validation(format!("referenced attachment is missing: {path}")))?;
            let content = self.store.cat_blob(&entry.oid)?;
            self.store.validate_content_for_path(path, &content)?;
            let mut attachment = Dict::new();
            attachment.insert("path", path.as_str());
            attachment.insert("blob", entry.oid.as_str());
            attachment.insert("size", content.len() as i64);
            attachment.insert(
                "mime_type",
                store::attachment_mime_for_filename(posix_name(path))?,
            );
            attachments.push(Value::Dict(attachment));
        }
        let mut result = Dict::new();
        result.insert("schema_version", CATALOG_SCHEMA_VERSION);
        result.insert("artifact_id", ticket.artifact_id.as_str());
        result.insert("ticket_id", ticket.ticket_id.as_str());
        result.insert("title", ticket.title.as_str());
        result.insert("status", ticket.status.as_str());
        result.insert("activity_at", format_instant(ticket.activity_at));
        result.insert("dependencies", strings(&ticket.dependencies));
        result.insert("state", RetentionState::Archived.value());
        result.insert("ticket_path", ticket.path.as_str());
        result.insert("ticket_blob", ticket.blob_id.as_str());
        result.insert("ticket_size", self.store.blob_size(&ticket.blob_id)? as i64);
        result.insert("attachments", Value::List(attachments));
        result.insert("source_commit", ticket.source_commit.as_str());
        result.insert("archived_at", format_instant(archived_at));
        result.insert("restored_at", Value::Null);
        result.insert("deleted_at", Value::Null);
        Ok(result)
    }

    fn verify_active_ticket(&self, ticket: &RetentionTicket, entries: &Entries) -> Result<()> {
        let entries = entry_map(entries);
        if entries
            .get(ticket.path.as_str())
            .is_none_or(|entry| entry.oid != ticket.blob_id)
        {
            return Err(concurrent(format!(
                "ticket {} changed before archival",
                ticket.ticket_id
            )));
        }
        let content = self.store.cat_blob(&ticket.blob_id)?;
        self.store
            .validate_content_for_path(&ticket.path, &content)?;
        for path in &ticket.attachment_paths {
            let attachment = entries
                .get(path.as_str())
                .ok_or_else(|| validation(format!("referenced attachment is missing: {path}")))?;
            self.store
                .validate_content_for_path(path, &self.store.cat_blob(&attachment.oid)?)?;
        }
        Ok(())
    }

    fn verify_archived_reachability(
        &self,
        commit_id: &str,
        tickets: &[RetentionTicket],
        catalog: &Catalog,
    ) -> Result<()> {
        for ticket in tickets {
            let entry = catalog_entry_of(catalog, &ticket.artifact_id)
                .ok_or_else(|| key_error(&ticket.artifact_id))?;
            let source_commit = index_str(entry, "source_commit")?;
            if self
                .store
                .git(
                    &["merge-base", "--is-ancestor", &source_commit, commit_id],
                    &[],
                    None,
                    &[0, 1, 128],
                )?
                .status
                != 0
            {
                return Err(validation(
                    "archive source commit is not reachable from archive head",
                ));
            }
            self.verified_historical_blob(
                &source_commit,
                &index_str(entry, "ticket_path")?,
                &index_str(entry, "ticket_blob")?,
            )?;
            for attachment in entry
                .get("attachments")
                .and_then(Value::as_list)
                .unwrap_or_default()
            {
                let attachment = attachment.as_dict().ok_or_else(|| key_error("path"))?;
                self.verified_historical_blob(
                    &source_commit,
                    &index_str(attachment, "path")?,
                    &index_str(attachment, "blob")?,
                )?;
            }
        }
        Ok(())
    }

    fn verified_catalog_markdown(&self, artifact_head: &str, entry: &Dict) -> Result<Vec<u8>> {
        let source_commit = entry.string("source_commit");
        if !self.object_exists(&source_commit)? {
            return Err(missing_historical_object());
        }
        if self
            .store
            .git(
                &["merge-base", "--is-ancestor", &source_commit, artifact_head],
                &[],
                None,
                &[0, 1, 128],
            )?
            .status
            != 0
        {
            return Err(validation(
                "archive catalog source commit is not reachable from the current artifact head",
            ));
        }
        let content = self.verified_historical_blob(
            &source_commit,
            &entry.string("ticket_path"),
            &entry.string("ticket_blob"),
        )?;
        catalog::validate_catalog_ticket_metadata(entry, &content, &ACTIVITY_FIELDS)?;
        Ok(content)
    }

    fn catalog_attachment_metadata(&self, catalog: &Catalog, entry: &Dict) -> Result<Vec<Dict>> {
        let mut ownership: HashMap<String, (String, String)> = HashMap::new();
        let mut catalog_attachments: Vec<(String, String, &Dict)> = Vec::new();
        for (owner_artifact_id, owner_entry) in catalog_entries(catalog) {
            let owner_ticket_id = owner_entry.string("ticket_id");
            let owner_label = if owner_ticket_id.is_empty() {
                owner_artifact_id.to_string()
            } else {
                owner_ticket_id.clone()
            };
            let owner_attachments: &[Value] = match owner_entry.get("attachments") {
                None => &[],
                Some(Value::List(items)) if items.iter().all(|item| item.as_dict().is_some()) => {
                    items
                }
                Some(_) => return Err(validation("archive catalog attachments must be a list")),
            };
            for attachment in owner_attachments.iter().filter_map(Value::as_dict) {
                let path = match attachment.get("path") {
                    Some(Value::Str(path)) if !path.is_empty() => path.clone(),
                    _ => {
                        return Err(validation(format!(
                            "archive catalog attachment path for {owner_label} is invalid"
                        )));
                    }
                };
                catalog_attachments.push((
                    owner_artifact_id.to_string(),
                    owner_ticket_id.clone(),
                    attachment,
                ));
                if let Some((prior_artifact, prior_ticket)) = ownership.get(&path) {
                    let prior_label = if prior_ticket.is_empty() {
                        prior_artifact
                    } else {
                        prior_ticket
                    };
                    return Err(validation(format!(
                        "archive catalog attachment path is not uniquely owned: {path} is listed by {prior_label} and {owner_label}; repair the catalog from the verified artifact source"
                    )));
                }
                ownership.insert(
                    path,
                    (owner_artifact_id.to_string(), owner_ticket_id.clone()),
                );
            }
        }

        for (owner_artifact_id, owner_ticket_id, attachment) in &catalog_attachments {
            let path = index_str(attachment, "path")?;
            let expected_path = format!(
                ".orchestrator/attachments/{owner_ticket_id}/{}",
                posix_name(&path)
            );
            if owner_ticket_id.is_empty() || path != expected_path {
                let owner_label = if owner_ticket_id.is_empty() {
                    owner_artifact_id
                } else {
                    owner_ticket_id
                };
                return Err(validation(format!(
                    "archive catalog attachment path {} is not owned by {owner_label}; repair the catalog from the verified artifact source",
                    pystr::repr(&path)
                )));
            }
        }

        let attachments: &[Value] = match entry.get("attachments") {
            None => &[],
            Some(Value::List(items)) => items,
            Some(_) => return Err(validation("archive catalog attachments must be a list")),
        };
        let mut validated = Vec::new();
        for attachment in attachments {
            let attachment = attachment
                .as_dict()
                .ok_or_else(|| validation("archive catalog attachments must be a list"))?;
            let path = index_str(attachment, "path")?;
            let canonical_mime = store::attachment_mime_for_filename(posix_name(&path)).map_err(
                |error| {
                    validation(format!(
                        "archive catalog attachment type metadata is invalid for {path}: {error}; repair the catalog from the verified artifact source"
                    ))
                },
            )?;
            if !attachment
                .get("mime_type")
                .is_some_and(|value| value.is_str(canonical_mime))
            {
                return Err(validation(format!(
                    "archive catalog attachment MIME metadata is inconsistent for {path}; repair the catalog from the verified artifact source"
                )));
            }
            let size_valid = match attachment.get("size") {
                Some(Value::Int(size)) => *size >= 0,
                Some(Value::BigInt(digits)) => !digits.starts_with('-'),
                _ => false,
            };
            if !size_valid {
                return Err(validation(format!(
                    "archive catalog attachment size metadata is invalid for {path}; repair the catalog from the verified artifact source"
                )));
            }
            if !attachment
                .get("blob")
                .and_then(Value::as_str)
                .is_some_and(is_object_id)
            {
                return Err(validation(format!(
                    "archive catalog attachment blob metadata is invalid for {path}; repair the catalog from the verified artifact source"
                )));
            }
            validated.push(attachment.clone());
        }
        Ok(validated)
    }

    /// IDs verified for these catalog bytes at `head` or one of its ancestors.
    fn catalog_entries_verified_at(
        &self,
        head: &str,
        catalog_digest: &str,
    ) -> Result<HashSet<String>> {
        let cached = VERIFIED_CATALOGS
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .get(&verified_catalog_key(self.store))
            .cloned();
        let Some((digest, verified_head, verified_ids)) = cached else {
            return Ok(HashSet::new());
        };
        if digest != catalog_digest {
            return Ok(HashSet::new());
        }
        if verified_head != head
            && self
                .store
                .git(
                    &["merge-base", "--is-ancestor", &verified_head, head],
                    &[],
                    None,
                    &[0, 1, 128],
                )?
                .status
                != 0
        {
            return Ok(HashSet::new());
        }
        Ok(verified_ids)
    }

    fn verified_catalog_entry(
        &self,
        artifact_head: &str,
        catalog: &Catalog,
        entry: &Dict,
        attachments: Option<&[Dict]>,
    ) -> Result<Vec<u8>> {
        let owned;
        let attachments = match attachments {
            Some(attachments) => attachments,
            None => {
                owned = self.catalog_attachment_metadata(catalog, entry)?;
                &owned
            }
        };
        let content = self.verified_catalog_markdown(artifact_head, entry)?;
        let source_commit = entry.string("source_commit");
        for attachment in attachments {
            let path = index_str(attachment, "path")?;
            let historical = self
                .verified_historical_blob(&source_commit, &path, &index_str(attachment, "blob")?)
                .and_then(|historical| {
                    self.store.validate_content_for_path(&path, &historical)?;
                    Ok(historical)
                })
                .map_err(|error| {
                    if error.kind.is_validation() {
                        validation(format!(
                            "{error}; repair the catalog from the verified artifact source"
                        ))
                    } else {
                        error
                    }
                })?;
            let size = attachment.get("size").ok_or_else(|| key_error("size"))?;
            if !json::py_eq(size, &Value::Int(historical.len() as i64)) {
                return Err(validation(format!(
                    "archive catalog attachment size metadata is inconsistent for {path}; repair the catalog from the verified artifact source"
                )));
            }
        }
        Ok(content)
    }

    fn verified_historical_blob(
        &self,
        commit_id: &str,
        path: &str,
        expected_blob: &str,
    ) -> Result<Vec<u8>> {
        if !self.object_exists(commit_id)? || !self.object_exists(expected_blob)? {
            return Err(missing_historical_object());
        }
        let result = self.store.git(
            &["rev-parse", &format!("{commit_id}:{path}")],
            &[],
            None,
            &[0, 128],
        )?;
        if result.status != 0 {
            return Err(validation(format!(
                "archive catalog path is absent from source commit: {path}"
            )));
        }
        let actual = result.line();
        if actual != expected_blob {
            return Err(validation(format!(
                "archive catalog blob mismatch for {path}: expected {expected_blob}, found {actual}"
            )));
        }
        self.store.cat_blob(expected_blob)
    }

    fn object_exists(&self, object_id: &str) -> Result<bool> {
        if !is_object_id(object_id) {
            return Ok(false);
        }
        Ok(self
            .store
            .git(&["cat-file", "-e", object_id], &[], None, &[0, 1, 128])?
            .status
            == 0)
    }

    fn resume_archive(
        &self,
        mut transaction: Dict,
        synchronizer: Option<&ArtifactSyncEngine<'_>>,
    ) -> Result<ArchiveResult> {
        self.validate_transaction(&transaction)?;
        let base_head = index_str(&transaction, "base_head")?;
        let candidate_head = index_str(&transaction, "candidate_head")?;
        let ticket_ids: Vec<String> = transaction
            .get("ticket_ids")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .map(Value::py_str)
            .collect();
        let mut phase = index_str(&transaction, "phase")?;
        let mut proofs = Vec::new();
        for value in transaction
            .get("proofs")
            .and_then(Value::as_list)
            .unwrap_or_default()
        {
            let value = value.as_dict().ok_or_else(|| key_error("source_commit"))?;
            proofs.push(RemoteProof {
                source_commit: index_str(value, "source_commit")?,
                path: index_str(value, "path")?,
                blob_id: index_str(value, "blob_id")?,
                sha256: index_str(value, "sha256")?,
            });
        }
        if !self.object_exists(&candidate_head)? {
            return Err(validation(
                "prepared retention commit is unavailable; active files were retained",
            ));
        }
        if self.store.first_parent(&candidate_head)?.as_deref() != Some(base_head.as_str()) {
            return Err(validation(
                "prepared retention commit no longer matches its base",
            ));
        }
        self.ensure_transaction_scratch(&transaction)?;

        let current = self.store.head()?;
        if phase == "prepared" {
            if current.as_deref() != Some(base_head.as_str()) {
                return Err(concurrent(
                    "artifact authority changed before remote archive verification",
                ));
            }
            let confirmation = self.transaction_confirmation(&transaction)?;
            self.validate_remote_transaction(synchronizer, Some(&confirmation))?;
            let synchronizer = synchronizer.expect("validated above");
            let result = synchronizer.publish_prepared(
                &candidate_head,
                &base_head,
                &proofs,
                Some(&confirmation.remote_url_sha256),
                Some(&confirmation.push_url_sha256),
            )?;
            if result.state != SyncState::Clean {
                let last_error = result
                    .recovery
                    .clone()
                    .filter(|text| !text.is_empty())
                    .unwrap_or_else(|| {
                        "Prepared archive publication could not be independently verified."
                            .to_string()
                    });
                transaction.insert("last_error", last_error.as_str());
                if matches!(
                    result.state,
                    SyncState::Ahead | SyncState::Behind | SyncState::Conflict
                ) && result
                    .remote_head
                    .as_deref()
                    .is_some_and(|head| !head.is_empty())
                {
                    self.discard_prepared_transaction(&transaction)?;
                    return Ok(ArchiveResult::pending(
                        ticket_ids,
                        format!(
                            "{last_error} The unpublished prepared transaction was discarded; synchronize, preview, and retry."
                        ),
                    ));
                }
                self.write_transaction(&transaction)?;
                return Ok(ArchiveResult::pending(ticket_ids, last_error));
            }
            transaction.insert("phase", "published");
            transaction.insert("last_error", Value::Null);
            transaction.insert(
                "verified_remote_head",
                result
                    .remote_head
                    .as_deref()
                    .map_or(Value::Null, Value::from),
            );
            self.write_transaction(&transaction)?;
            self.inject("after_remote_verification")?;
            phase = "published".to_string();
        }

        let current = self.store.head()?;
        if phase == "published" {
            let current = current
                .filter(|head| *head == base_head || *head == candidate_head)
                .ok_or_else(|| {
                    concurrent("artifact authority differs from the verified archive transaction")
                })?;
            self.store.ensure_materialization_consistent(&base_head)?;
            if current == base_head {
                let update = self.store.git(
                    &[
                        "update-ref",
                        &self.store.artifact_ref,
                        &candidate_head,
                        &base_head,
                    ],
                    &[],
                    None,
                    &[0, 128],
                )?;
                if update.status != 0 {
                    return Err(concurrent(
                        "artifact authority changed during verified archive adoption",
                    ));
                }
            }
            self.inject("after_local_ref_update")?;
            transaction.insert("phase", "local_ref_advanced");
            self.write_transaction(&transaction)?;
            phase = "local_ref_advanced".to_string();
        }

        if phase == "local_ref_advanced" {
            if self.store.head()?.as_deref() != Some(candidate_head.as_str()) {
                return Err(concurrent(
                    "verified archive commit is no longer the local artifact authority",
                ));
            }
            self.store.recover_materialization_transaction()?;
            self.store.materialize(&candidate_head, true)?;
            transaction.insert("phase", "materialized");
            self.write_transaction(&transaction)?;
            self.inject("after_archive_materialization")?;
            phase = "materialized".to_string();
        }

        if phase != "materialized" {
            return Err(validation(format!(
                "unsupported retention transaction phase: {}",
                pystr::repr(&phase)
            )));
        }
        if self.store.head()?.as_deref() != Some(candidate_head.as_str()) {
            return Err(concurrent(
                "materialized archive transaction lost canonical authority",
            ));
        }
        self.store.recover_materialization_transaction()?;
        self.store
            .ensure_materialization_consistent(&candidate_head)?;
        self.store.git(
            &[
                "update-ref",
                "-d",
                &index_str(&transaction, "scratch_ref")?,
                &candidate_head,
            ],
            &[],
            None,
            &[0, 128],
        )?;
        self.remove_transaction()?;
        Ok(ArchiveResult::new(
            RetentionState::Archived,
            Some(WriteResult {
                event_id: index_str(&transaction, "event_id")?,
                commit_id: candidate_head.clone(),
                tree_id: self.store.tree_id(&candidate_head)?,
                base_commit: Some(base_head),
                idempotent: false,
                warnings: Vec::new(),
            }),
            ticket_ids,
        ))
    }

    fn archive_proofs(
        &self,
        candidate_head: &str,
        tickets: &[RetentionTicket],
        base_entries: &Entries,
        candidate_entries: &Entries,
    ) -> Result<Vec<RemoteProof>> {
        let base_entries = entry_map(base_entries);
        let candidate_entries = entry_map(candidate_entries);
        let mut proofs = Vec::new();
        for ticket in tickets {
            let content = self.store.cat_blob(&ticket.blob_id)?;
            proofs.push(RemoteProof {
                source_commit: ticket.source_commit.clone(),
                path: ticket.path.clone(),
                blob_id: ticket.blob_id.clone(),
                sha256: hex_digest(&content),
            });
            for path in &ticket.attachment_paths {
                let entry = base_entries.get(path.as_str()).ok_or_else(|| {
                    validation(format!("referenced attachment is missing: {path}"))
                })?;
                let attachment = self.store.cat_blob(&entry.oid)?;
                proofs.push(RemoteProof {
                    source_commit: ticket.source_commit.clone(),
                    path: path.clone(),
                    blob_id: entry.oid.clone(),
                    sha256: hex_digest(&attachment),
                });
            }
        }
        let catalog_entry = candidate_entries
            .get(CATALOG_PATH)
            .ok_or_else(|| validation("prepared archive commit has no catalog"))?;
        let catalog_content = self.store.cat_blob(&catalog_entry.oid)?;
        proofs.push(RemoteProof {
            source_commit: candidate_head.to_string(),
            path: CATALOG_PATH.to_string(),
            blob_id: catalog_entry.oid.clone(),
            sha256: hex_digest(&catalog_content),
        });
        proofs.sort_by(|left, right| {
            (&left.source_commit, &left.path).cmp(&(&right.source_commit, &right.path))
        });
        Ok(proofs)
    }

    fn validate_remote_transaction(
        &self,
        synchronizer: Option<&ArtifactSyncEngine<'_>>,
        confirmation: Option<&ArchiveRemoteConfirmation>,
    ) -> Result<ArchiveRemoteConfirmation> {
        if self.remote_mode != "enabled" {
            return Err(validation(
                "terminal cleanup remains preview-only until a GitHub remote is selected and confirmed",
            ));
        }
        let Some(synchronizer) = synchronizer else {
            return Err(validation(
                "remote-enabled retention requires the exact-ref verified synchronizer",
            ));
        };
        let confirmation = confirmation
            .or(self.remote_confirmation.as_ref())
            .filter(|confirmation| {
                confirmation.service == "github" && confirmation.exposure_confirmed
            })
            .ok_or_else(|| {
                validation("GitHub archival exposure has not been explicitly confirmed")
            })?;
        if synchronizer.remote_name.as_deref() != Some(confirmation.remote_name.as_str()) {
            return Err(validation(
                "confirmed GitHub remote does not match the synchronizer",
            ));
        }
        let (remote_url, push_url) = configured_remote_urls(self.store, &confirmation.remote_name)?;
        if sha256_text(&remote_url) != confirmation.remote_url_sha256 {
            return Err(validation(
                "the selected GitHub remote URL changed after exposure confirmation",
            ));
        }
        if sha256_text(&push_url) != confirmation.push_url_sha256 {
            return Err(validation(
                "the selected GitHub push destination changed after exposure confirmation",
            ));
        }
        Ok(confirmation.clone())
    }

    fn scratch_ref(&self, event_id: &str) -> String {
        let digest = sha256_text(event_id);
        format!(
            "refs/relay-runner/retention/{}/{}",
            self.store.project_id,
            &digest[..32]
        )
    }

    fn transaction_confirmation(&self, transaction: &Dict) -> Result<ArchiveRemoteConfirmation> {
        let Some(Value::Dict(value)) = transaction.get("remote_confirmation") else {
            return Err(validation(
                "retention transaction has no remote confirmation",
            ));
        };
        Ok(ArchiveRemoteConfirmation {
            service: get_str(value, "service", ""),
            remote_name: get_str(value, "remote_name", ""),
            remote_url_sha256: get_str(value, "remote_url_sha256", ""),
            push_url_sha256: get_str(value, "push_url_sha256", ""),
            exposure_confirmed: matches!(value.get("exposure_confirmed"), Some(Value::Bool(true))),
        })
    }

    fn rev_parse_ref(&self, name: &str) -> Result<Option<String>> {
        let found = self
            .store
            .git(&["rev-parse", "--verify", name], &[], None, &[0, 128])?;
        Ok((found.status == 0).then(|| found.line()))
    }

    fn ensure_transaction_scratch(&self, transaction: &Dict) -> Result<()> {
        let scratch_ref = index_str(transaction, "scratch_ref")?;
        let candidate_head = index_str(transaction, "candidate_head")?;
        if let Some(found) = self.rev_parse_ref(&scratch_ref)? {
            if found != candidate_head {
                return Err(concurrent(
                    "retention scratch ref already names another commit",
                ));
            }
            return Ok(());
        }
        let zero = self.store.zero_oid()?;
        let update = self.store.git(
            &["update-ref", &scratch_ref, &candidate_head, &zero],
            &[],
            None,
            &[0, 128],
        )?;
        if update.status != 0 {
            return Err(concurrent("retention scratch ref changed during recovery"));
        }
        Ok(())
    }

    /// Pin a prepared candidate before making its journal durable.
    fn publish_transaction_scratch(&self, transaction: &Dict) -> Result<()> {
        if fs::metadata(&self.transaction_path).is_ok() {
            return Err(concurrent(
                "another retention transaction appeared before candidate preparation",
            ));
        }
        let scratch_ref = index_str(transaction, "scratch_ref")?;
        let candidate_head = index_str(transaction, "candidate_head")?;
        let previous = match self.rev_parse_ref(&scratch_ref)? {
            Some(found) => found,
            None => self.store.zero_oid()?,
        };
        if previous == candidate_head {
            return Ok(());
        }
        let update = self.store.git(
            &["update-ref", &scratch_ref, &candidate_head, &previous],
            &[],
            None,
            &[0, 128],
        )?;
        if update.status != 0 {
            return Err(concurrent(
                "retention scratch ref changed before journal publication",
            ));
        }
        Ok(())
    }

    fn discard_prepared_transaction(&self, transaction: &Dict) -> Result<()> {
        let head = self.store.head()?;
        let base_matches = match (transaction.get("base_head"), &head) {
            (Some(Value::Str(base)), Some(head)) => base == head,
            (None | Some(Value::Null), None) => true,
            _ => false,
        };
        if !transaction
            .get("phase")
            .is_some_and(|phase| phase.is_str("prepared"))
            || !base_matches
        {
            return Err(concurrent(
                "only an unpublished prepared retention transaction can be discarded",
            ));
        }
        self.store.git(
            &[
                "update-ref",
                "-d",
                &index_str(transaction, "scratch_ref")?,
                &index_str(transaction, "candidate_head")?,
            ],
            &[],
            None,
            &[0, 128],
        )?;
        self.remove_transaction()
    }

    fn read_transaction(&self) -> Result<Option<Dict>> {
        if fs::metadata(&self.transaction_path).is_err() {
            return Ok(None);
        }
        let corrupt = |detail: String| {
            validation(format!(
                "retention transaction journal is corrupt: {detail}"
            ))
        };
        let bytes = fs::read(&self.transaction_path).map_err(|error| corrupt(error.to_string()))?;
        let text = pystr::universal_newlines(pystr::decode_utf8(&bytes)?);
        let value = json::parse(&text).ok_or_else(|| corrupt("Expecting value".to_string()))?;
        let Value::Dict(value) = value else {
            return Err(validation("retention transaction journal is not an object"));
        };
        self.validate_transaction(&value)?;
        Ok(Some(value))
    }

    fn write_transaction(&self, transaction: &Dict) -> Result<()> {
        self.validate_transaction(transaction)?;
        let directory = self
            .transaction_path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        fs::create_dir_all(&directory)?;
        let temporary = temporary_beside(&self.transaction_path);
        let written = (|| -> Result<()> {
            let mut handle = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)?;
            handle
                .write_all((canonical_json(&Value::Dict(transaction.clone())) + "\n").as_bytes())?;
            handle.flush()?;
            handle.sync_all()?;
            drop(handle);
            fs::rename(&temporary, &self.transaction_path)?;
            fsync_directory(&directory)
        })();
        let _ = fs::remove_file(&temporary);
        written
    }

    fn remove_transaction(&self) -> Result<()> {
        match fs::remove_file(&self.transaction_path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                return Err(error.into());
            }
            _ => {}
        }
        fsync_directory(
            self.transaction_path
                .parent()
                .unwrap_or_else(|| Path::new("/")),
        )
    }

    fn validate_transaction(&self, transaction: &Dict) -> Result<()> {
        if !transaction.get("schema_version").is_some_and(|value| {
            json::py_eq(value, &Value::Int(RETENTION_TRANSACTION_SCHEMA_VERSION))
        }) {
            return Err(validation("retention transaction schema is unsupported"));
        }
        if !transaction
            .get("project_id")
            .is_some_and(|value| value.is_str(&self.store.project_id))
        {
            return Err(validation(
                "retention transaction belongs to another project",
            ));
        }
        for key in [
            "event_id",
            "device_id",
            "actor_type",
            "phase",
            "base_head",
            "candidate_head",
            "scratch_ref",
        ] {
            if !matches!(transaction.get(key), Some(Value::Str(value)) if !value.is_empty()) {
                return Err(validation("retention transaction journal is incomplete"));
            }
        }
        let phase = transaction.string("phase");
        if ![
            "prepared",
            "published",
            "local_ref_advanced",
            "materialized",
        ]
        .contains(&phase.as_str())
        {
            return Err(validation("retention transaction phase is invalid"));
        }
        if transaction.string("scratch_ref") != self.scratch_ref(&transaction.string("event_id")) {
            return Err(validation("retention transaction scratch ref is invalid"));
        }
        if !matches!(transaction.get("ticket_ids"), Some(Value::List(items)) if !items.is_empty()) {
            return Err(validation("retention transaction has no ticket identities"));
        }
        if !matches!(
            transaction.get("proofs"),
            Some(Value::List(items))
                if !items.is_empty() && items.iter().all(|item| item.as_dict().is_some())
        ) {
            return Err(validation("retention transaction proofs are incomplete"));
        }
        let confirmation = self.transaction_confirmation(transaction)?;
        if confirmation.service != "github"
            || !confirmation.exposure_confirmed
            || !is_remote_name(&confirmation.remote_name)
            || !is_hex(&confirmation.remote_url_sha256, &[64])
            || !is_hex(&confirmation.push_url_sha256, &[64])
        {
            return Err(validation(
                "retention transaction remote confirmation is invalid",
            ));
        }
        Ok(())
    }

    pub fn catalog(&self, head: &str) -> Result<Catalog> {
        let snapshot = self.store.snapshot()?;
        if snapshot.commit_id != head {
            return Err(concurrent(
                "artifact head changed while reading archive catalog",
            ));
        }
        parse_catalog(snapshot.file(CATALOG_PATH).unwrap_or_default())
    }

    pub fn head_required(&self) -> Result<String> {
        self.store
            .head()?
            .filter(|head| !head.is_empty())
            .ok_or_else(|| validation("artifact store is not initialized"))
    }

    fn require_enabled(&self) -> Result<()> {
        if self.enabled {
            Ok(())
        } else {
            Err(validation(
                "retention is preview-only until explicitly enabled",
            ))
        }
    }

    fn inject(&self, stage: &str) -> Result<()> {
        match &self.failure_injector {
            Some(injector) => injector(stage),
            None => Ok(()),
        }
    }
}

fn proof_dict(proof: &RemoteProof) -> Dict {
    let mut result = Dict::new();
    result.insert("source_commit", proof.source_commit.as_str());
    result.insert("path", proof.path.as_str());
    result.insert("blob_id", proof.blob_id.as_str());
    result.insert("sha256", proof.sha256.as_str());
    result
}

/// `_prior_result`.
fn prior_result(store: &ArtifactStore, event_id: &str, commit_id: &str) -> Result<WriteResult> {
    Ok(WriteResult {
        event_id: event_id.to_string(),
        commit_id: commit_id.to_string(),
        tree_id: store.tree_id(commit_id)?,
        base_commit: store.first_parent(commit_id)?,
        idempotent: true,
        warnings: Vec::new(),
    })
}

// -- the daemon's payloads (services/orchestrator.py) ----------------------------

/// `_retention_ticket_payload`.
pub fn ticket_payload(ticket: &RetentionTicket) -> Value {
    let mut result = Dict::new();
    result.insert("ticket_id", ticket.ticket_id.as_str());
    result.insert("artifact_id", ticket.artifact_id.as_str());
    result.insert("title", ticket.title.as_str());
    result.insert("status", ticket.status.as_str());
    result.insert("activity_at", ticket.activity_at.isoformat_z());
    result.insert("dependencies", strings(&ticket.dependencies));
    result.insert("attachment_paths", strings(&ticket.attachment_paths));
    result.insert("exemptions", strings(&ticket.exemptions));
    result.insert("materialized", ticket.materialized);
    Value::Dict(result)
}

/// `_retention_plan_payload` for an already computed plan.
pub fn plan_value(plan: &RetentionPlan) -> Value {
    let mut result = Dict::new();
    result.insert("schema_version", plan.schema_version);
    result.insert("policy", plan.policy.as_str());
    result.insert("limit", plan.limit as i64);
    result.insert("project_id", plan.project_id.as_str());
    result.insert("artifact_head", plan.artifact_head.as_str());
    result.insert("evaluated_at", plan.evaluated_at.isoformat_z());
    result.insert(
        "retained_terminal_ids",
        strings(&plan.retained_terminal_ids()),
    );
    result.insert("nonterminal_ids", strings(&plan.nonterminal_ids()));
    result.insert("eviction_candidate_ids", strings(&plan.candidate_ids()));
    result.insert("materialize_ids", strings(&plan.materialize_ids()));
    let mut overage = Dict::new();
    for (ticket_id, reasons) in plan.temporary_overage() {
        overage.insert(&ticket_id, strings(&reasons));
    }
    result.insert("temporary_overage", overage);
    result.insert(
        "retained_terminal",
        Value::List(plan.retained_terminal.iter().map(ticket_payload).collect()),
    );
    result.insert(
        "eviction_candidates",
        Value::List(plan.candidates.iter().map(ticket_payload).collect()),
    );
    Value::Dict(result)
}

/// `_retention_plan_payload(manager)`: the `GET /v1/artifacts/retention/preview`
/// body.
pub fn plan_payload(manager: &ArtifactRetentionManager<'_>) -> Result<Value> {
    Ok(plan_value(&manager.preview(None)?))
}

/// `artifact_retention_status`'s composition: the
/// `GET /v1/artifacts/retention/status` body. `confirmation` is the
/// automatic or explicit exposure confirmation the daemon resolved.
pub fn status_payload(
    manager: &ArtifactRetentionManager<'_>,
    synchronizer: Option<&ArtifactSyncEngine<'_>>,
    confirmation: Option<&ArchiveRemoteConfirmation>,
) -> Result<Value> {
    let plan = plan_payload(manager)?;
    let has_candidates = plan
        .as_dict()
        .and_then(|plan| plan.get("eviction_candidate_ids"))
        .is_some_and(Value::truthy);
    let transaction = manager.transaction_status()?;
    let mut blocked_reasons: Vec<String> = Vec::new();
    let mut remote_status = Value::Null;
    if has_candidates {
        match synchronizer {
            None => blocked_reasons.push(
                "Terminal cleanup is preview-only until a GitHub remote is selected and confirmed."
                    .to_string(),
            ),
            Some(synchronizer) => {
                let observed = synchronizer.status()?;
                let mut remote = Dict::new();
                remote.insert("state", observed.state.value());
                remote.insert(
                    "local_head",
                    observed
                        .local_head
                        .as_deref()
                        .map_or(Value::Null, Value::from),
                );
                remote.insert(
                    "remote_head",
                    observed
                        .remote_head
                        .as_deref()
                        .map_or(Value::Null, Value::from),
                );
                remote.insert(
                    "recovery",
                    observed
                        .recovery
                        .as_deref()
                        .map_or(Value::Null, Value::from),
                );
                remote_status = Value::Dict(remote);
                if observed.state != SyncState::Clean {
                    blocked_reasons.push(
                        observed
                            .recovery
                            .clone()
                            .filter(|text| !text.is_empty())
                            .unwrap_or_else(|| {
                                format!("Artifact synchronization is {}.", observed.state.value())
                            }),
                    );
                }
                match confirm_github_remote(
                    manager.store,
                    synchronizer.remote_name.as_deref().unwrap_or(""),
                    true,
                ) {
                    Ok(_) => {}
                    Err(error) if error.kind.is_validation() => blocked_reasons.push(error.message),
                    Err(error) => return Err(error),
                }
            }
        }
    }
    if let Some(last_error) = transaction.truthy("last_error") {
        blocked_reasons.push(last_error.py_str());
    } else if transaction.truthy("retry_available").is_some() {
        blocked_reasons.push(
            "A retention publication transaction is incomplete and must be retried.".to_string(),
        );
    }
    let retry_actions: Vec<String> = if transaction.truthy("retry_available").is_some() {
        vec!["POST /v1/artifacts/retention/retry".to_string()]
    } else if !blocked_reasons.is_empty() && has_candidates {
        vec!["POST /v1/artifacts/retention/apply".to_string()]
    } else {
        Vec::new()
    };
    let mut result = Dict::new();
    result.insert(
        "state",
        if blocked_reasons.is_empty() {
            "ready"
        } else {
            "blocked"
        },
    );
    result.insert("remote_mode", manager.remote_mode.as_str());
    result.insert(
        "remote_name",
        synchronizer
            .and_then(|synchronizer| synchronizer.remote_name.as_deref())
            .map_or(Value::Null, Value::from),
    );
    result.insert(
        "exposure_confirmation_required",
        has_candidates && manager.remote_mode == "enabled" && confirmation.is_none(),
    );
    result.insert("plan", plan);
    result.insert("transaction", transaction);
    result.insert("remote", remote_status);
    result.insert("blocked_reasons", strings(&blocked_reasons));
    result.insert("retry_actions", strings(&retry_actions));
    Ok(Value::Dict(result))
}

/// One history card as `artifact_history_search` returns it.
pub fn history_card_payload(card: &HistoricalCard) -> Value {
    let mut result = Dict::new();
    result.insert("artifact_id", card.artifact_id.as_str());
    result.insert("ticket_id", card.ticket_id.as_str());
    result.insert("title", card.title.as_str());
    result.insert("status", card.status.as_str());
    result.insert("activity_at", card.activity_at.isoformat_z());
    result.insert("state", card.state.value());
    result.insert("attachment_count", card.attachment_count);
    result.insert("attachment_bytes", card.attachment_bytes);
    Value::Dict(result)
}

/// `artifact_history_search` for an artifact-backed project: the
/// `GET /v1/artifacts/history/search` body.
pub fn history_search_payload(
    manager: &ArtifactRetentionManager<'_>,
    query: &str,
) -> Result<Value> {
    let mut result = Dict::new();
    result.insert(
        "history",
        Value::List(
            manager
                .historical_search(query)?
                .iter()
                .map(history_card_payload)
                .collect(),
        ),
    );
    Ok(Value::Dict(result))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn github_urls_follow_the_ignorecase_patterns() {
        for url in [
            "https://github.com/owner/repo",
            "HTTPS://GitHub.COM/owner/repo.git",
            "ssh://git@github.com/owner/repo",
            "git@github.com:owner/repo",
            "git@g\u{131}thub.com:owner/repo",
        ] {
            assert!(is_github_url(url), "{url}");
        }
        for url in [
            "https://github.com/owner",
            "https://github.com/owner/repo/extra",
            "https://gitlab.com/owner/repo",
            "/tmp/remote.git",
            "https://github.com/owner/re po",
        ] {
            assert!(!is_github_url(url), "{url}");
        }
    }

    #[test]
    fn front_matter_helpers_match_python() {
        let content = b"---\nid: RR-1\ntitle: \"Quoted\"\nstatus: done\n---\nbody\n";
        let front = front_matter(content).unwrap();
        assert_eq!(front_get(&front, "title"), Some("Quoted"));
        let updated =
            set_front_matter_value(content, "activity_at", "2026-01-01T00:00:00Z").unwrap();
        assert_eq!(
            String::from_utf8(updated).unwrap(),
            "---\nid: RR-1\ntitle: \"Quoted\"\nstatus: done\nactivity_at: 2026-01-01T00:00:00Z\n---\nbody\n"
        );
        assert_eq!(parse_list("[RR-1, 'RR-2', ]"), vec!["RR-1", "RR-2"]);
        assert!(front_matter(b"no front matter").is_err());
        assert_eq!(posix_stem(".orchestrator/RR-1.md"), "RR-1");
        assert_eq!(posix_name(".orchestrator/attachments/RR-1/"), "RR-1");
    }

    #[test]
    fn retention_state_values_round_trip() {
        for state in RetentionState::ALL {
            assert_eq!(RetentionState::from_value(state.value()).unwrap(), state);
        }
        assert_eq!(
            RetentionState::from_value("bogus").unwrap_err().message,
            "'bogus' is not a valid RetentionState"
        );
    }
}
