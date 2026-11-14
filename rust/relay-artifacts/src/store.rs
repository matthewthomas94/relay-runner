//! `services/artifact_store.py`: the per-project writer for the orphan
//! artifact ref `refs/heads/relay/artifacts`.
//!
//! It uses Git plumbing with a private index and never checks out the ref,
//! changes the source branch, stages a source path or edits a remote. One
//! typed mutation becomes one compare-and-swap commit on the ref, which is
//! then materialized into the repository's `.orchestrator` projection.
//!
//! Everything a Python daemon would read back is the Python store's own form:
//! the commit (tree, message, trailers, the event digest), the
//! `materialization.json`, `materialization-journal.json` and
//! `history-verification.json` files, the projection's file modes, and the
//! `flock` on `locks/<project>.lock` that serializes writers across both
//! daemons. Failures carry the Python exception class and message.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, LazyLock, Mutex};
use std::thread::ThreadId;
use std::time::{SystemTime, UNIX_EPOCH};

use fancy_regex::Regex;
use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256::hex_digest;

use crate::git::{self, Output};
use crate::notes::{self, NOTE_MAX_BYTES};
use crate::{Error, ErrorKind, Result, paths, pystr, toml};

pub const ARTIFACT_REF: &str = "refs/heads/relay/artifacts";
pub const TICKET_MAX_BYTES: usize = 256 * 1024;
pub const ATTACHMENT_MAX_BYTES: usize = 10 * 1024 * 1024;
pub const ATTACHMENT_TICKET_MAX_BYTES: u64 = 25 * 1024 * 1024;
pub const DEFAULT_PROJECT_WARNING_BYTES: u64 = 250 * 1024 * 1024;
pub const PROGRAM_EVENT_MAX_BYTES: usize = 256 * 1024;

/// Finder and other macOS services drop these into any folder a user opens;
/// they carry no Relay state, so the projection check skips them.
const IGNORED_MATERIALIZATION_NAMES: [&str; 6] = [
    ".DS_Store",
    ".localized",
    "Icon\r",
    ".Spotlight-V100",
    ".Trashes",
    ".fseventsd",
];
const MAX_DESCRIBED_MATERIALIZATION_PATHS: usize = 5;
const FORBIDDEN_JSON_KEYS: [&str; 9] = [
    "hidden_reasoning",
    "raw_audio",
    "raw_log",
    "raw_logs",
    "raw_transcript",
    "sensitive_transcript",
    "session_trace",
    "shell_trace",
    "tool_output",
];

// The Python patterns match bytes: `\b`, `\s` and IGNORECASE are ASCII-only
// there. Spelled out here so Unicode word characters, whitespace and case
// folding do not change what matches.
const WORD: &str = "[A-Za-z0-9_]";
const SPACE: &str = r"[ \t\n\r\x0b\x0c]";

/// Python's `\b` in a bytes pattern.
fn boundary() -> String {
    format!("(?:(?<={WORD})(?!{WORD})|(?<!{WORD})(?={WORD}))")
}

/// An ASCII literal matched as `re.IGNORECASE` matches bytes.
fn caseless(literal: &str) -> String {
    literal
        .chars()
        .map(|character| {
            if character.is_ascii_alphabetic() {
                format!(
                    "[{}{}]",
                    character.to_ascii_uppercase(),
                    character.to_ascii_lowercase()
                )
            } else {
                fancy_regex::escape(&character.to_string()).into_owned()
            }
        })
        .collect()
}

fn compile(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap_or_else(|error| panic!("invalid pattern {pattern:?}: {error}"))
}

static SECRET_PATTERNS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    let b = boundary();
    let names = ["api[_-]?key", "access[_-]?token", "client[_-]?secret"]
        .map(|name| {
            // Keep the `[_-]?` classes; only the letters become caseless.
            name.split("[_-]?")
                .map(caseless)
                .collect::<Vec<_>>()
                .join("[_-]?")
        })
        .join("|");
    vec![
        compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
        compile(&format!("{b}AKIA[0-9A-Z]{{16}}{b}")),
        compile(&format!("{b}gh[pousr]_[A-Za-z0-9]{{30,}}{b}")),
        compile(&format!("{b}github_pat_[A-Za-z0-9_]{{30,}}{b}")),
        compile(&format!("{b}sk-[A-Za-z0-9_-]{{20,}}{b}")),
        compile(&format!(
            "{b}(?:{names}){SPACE}*[:=]{SPACE}*['\"]?[A-Za-z0-9_./+=-]{{20,}}"
        )),
    ]
});

fn alternatives(words: &[&str]) -> String {
    words
        .iter()
        .map(|word| caseless(word))
        .collect::<Vec<_>>()
        .join("|")
}

static FORBIDDEN_TEXT_MARKERS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    vec![
        compile(&format!(
            "(?m)^{SPACE}*(?:{}){SPACE}*:",
            alternatives(&[
                "raw_transcript",
                "hidden_reasoning",
                "session_trace",
                "shell_trace"
            ])
        )),
        compile(&format!(
            "<{SPACE}*(?:{}){SPACE}*>",
            [
                "raw[_-]transcript",
                "hidden[_-]reasoning",
                "session[_-]trace"
            ]
            .map(|word| word
                .split("[_-]")
                .map(caseless)
                .collect::<Vec<_>>()
                .join("[_-]"))
            .join("|")
        )),
        compile(&format!(
            "(?m)^{SPACE}*{}(?:{}){}{SPACE}*$",
            caseless("-----BEGIN RAW "),
            alternatives(&["TRANSCRIPT", "SESSION TRACE"]),
            caseless("-----")
        )),
    ]
});

static FORBIDDEN_NOTE_MARKERS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    vec![
        compile(&format!(
            "(?m)^{SPACE}*(?:{}){SPACE}*:",
            alternatives(&[
                "hidden_reasoning",
                "session_trace",
                "shell_trace",
                "tool_output",
                "raw_audio"
            ])
        )),
        compile(&format!(
            "<{SPACE}*(?:{}){SPACE}*>",
            [
                "hidden[_-]reasoning",
                "session[_-]trace",
                "shell[_-]trace",
                "tool[_-]output",
                "raw[_-]audio"
            ]
            .map(|word| word
                .split("[_-]")
                .map(caseless)
                .collect::<Vec<_>>()
                .join("[_-]"))
            .join("|")
        )),
    ]
});

fn validation(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::Validation, message)
}

fn identity_error(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::Identity, message)
}

fn conflict(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::MaterializationConflict, message)
}

fn search(patterns: &[Regex], content: &[u8]) -> bool {
    let text = String::from_utf8_lossy(content);
    patterns
        .iter()
        .any(|pattern| pattern.is_match(text.as_ref()).unwrap_or(false))
}

/// One typed artifact operation, as the Python dataclasses define them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Operation {
    TicketWrite {
        ticket_id: String,
        artifact_id: String,
        markdown: Vec<u8>,
    },
    TicketDelete {
        ticket_id: String,
    },
    NoteWrite {
        note_id: String,
        artifact_id: String,
        project_id: String,
        markdown: Vec<u8>,
    },
    NoteDelete {
        note_id: String,
        artifact_id: String,
    },
    NoteIndexWrite {
        content: Vec<u8>,
    },
    AttachmentWrite {
        ticket_id: String,
        filename: String,
        mime_type: String,
        content: Vec<u8>,
    },
    AttachmentDelete {
        ticket_id: String,
        filename: String,
    },
    ConfigWrite {
        content: Vec<u8>,
    },
    ArchiveIndexWrite {
        content: Vec<u8>,
    },
    ProgramEventWrite {
        event_id: String,
        content: Vec<u8>,
    },
}

enum Field<'o> {
    Text(&'o str),
    Bytes(&'o [u8]),
}

impl Operation {
    /// The dataclass name and its fields, in declaration order.
    fn fields(&self) -> (&'static str, Vec<(&'static str, Field<'_>)>) {
        use Field::{Bytes, Text};
        match self {
            Operation::TicketWrite {
                ticket_id,
                artifact_id,
                markdown,
            } => (
                "TicketWrite",
                vec![
                    ("ticket_id", Text(ticket_id)),
                    ("artifact_id", Text(artifact_id)),
                    ("markdown", Bytes(markdown)),
                ],
            ),
            Operation::TicketDelete { ticket_id } => {
                ("TicketDelete", vec![("ticket_id", Text(ticket_id))])
            }
            Operation::NoteWrite {
                note_id,
                artifact_id,
                project_id,
                markdown,
            } => (
                "NoteWrite",
                vec![
                    ("note_id", Text(note_id)),
                    ("artifact_id", Text(artifact_id)),
                    ("project_id", Text(project_id)),
                    ("markdown", Bytes(markdown)),
                ],
            ),
            Operation::NoteDelete {
                note_id,
                artifact_id,
            } => (
                "NoteDelete",
                vec![
                    ("note_id", Text(note_id)),
                    ("artifact_id", Text(artifact_id)),
                ],
            ),
            Operation::NoteIndexWrite { content } => {
                ("NoteIndexWrite", vec![("content", Bytes(content))])
            }
            Operation::AttachmentWrite {
                ticket_id,
                filename,
                mime_type,
                content,
            } => (
                "AttachmentWrite",
                vec![
                    ("ticket_id", Text(ticket_id)),
                    ("filename", Text(filename)),
                    ("mime_type", Text(mime_type)),
                    ("content", Bytes(content)),
                ],
            ),
            Operation::AttachmentDelete {
                ticket_id,
                filename,
            } => (
                "AttachmentDelete",
                vec![("ticket_id", Text(ticket_id)), ("filename", Text(filename))],
            ),
            Operation::ConfigWrite { content } => {
                ("ConfigWrite", vec![("content", Bytes(content))])
            }
            Operation::ArchiveIndexWrite { content } => {
                ("ArchiveIndexWrite", vec![("content", Bytes(content))])
            }
            Operation::ProgramEventWrite { event_id, content } => (
                "ProgramEventWrite",
                vec![("event_id", Text(event_id)), ("content", Bytes(content))],
            ),
        }
    }
}

/// `ArtifactMutation`: one event, committed atomically or not at all.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mutation {
    pub event_id: String,
    pub actor_type: String,
    pub device_id: String,
    pub operations: Vec<Operation>,
    pub expected_base: Option<String>,
    pub provider: Option<String>,
    pub summary: String,
}

impl Mutation {
    /// A mutation with Python's defaults: no expected base, no provider and
    /// the summary "Relay artifact mutation".
    pub fn new(
        event_id: &str,
        actor_type: &str,
        device_id: &str,
        operations: Vec<Operation>,
    ) -> Self {
        Self {
            event_id: event_id.to_string(),
            actor_type: actor_type.to_string(),
            device_id: device_id.to_string(),
            operations,
            expected_base: None,
            provider: None,
            summary: "Relay artifact mutation".to_string(),
        }
    }
}

/// `ArtifactWriteResult`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WriteResult {
    pub event_id: String,
    pub commit_id: String,
    pub tree_id: String,
    pub base_commit: Option<String>,
    pub idempotent: bool,
    pub warnings: Vec<String>,
}

/// `ArtifactSnapshot`: one head's files, in `git ls-tree` order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub project_id: String,
    pub commit_id: String,
    pub tree_id: String,
    pub files: Vec<(String, Vec<u8>)>,
}

impl Snapshot {
    pub fn file(&self, path: &str) -> Option<&[u8]> {
        self.files
            .iter()
            .find(|(name, _)| name == path)
            .map(|(_, content)| content.as_slice())
    }
}

/// One `git ls-tree` entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeEntry {
    pub mode: String,
    pub kind: String,
    pub oid: String,
    pub path: String,
}

/// Tree entries by path, in `git ls-tree` order.
pub type Entries = Vec<(String, TreeEntry)>;

fn entry<'e>(entries: &'e Entries, path: &str) -> Option<&'e TreeEntry> {
    entries
        .iter()
        .find(|(name, _)| name == path)
        .map(|(_, entry)| entry)
}

/// Each operation's path and new bytes, `None` to delete.
type Prepared = Vec<(String, Option<Vec<u8>>)>;

/// A test hook called at named stages; an error aborts the operation there.
pub type FailureInjector = Box<dyn Fn(&str) -> Result<()> + Send + Sync>;

/// The constructor's keyword arguments.
pub struct StoreOptions {
    pub enabled: bool,
    pub artifact_ref: String,
    pub project_warning_bytes: u64,
    pub failure_injector: Option<FailureInjector>,
}

impl Default for StoreOptions {
    fn default() -> Self {
        Self {
            enabled: false,
            artifact_ref: ARTIFACT_REF.to_string(),
            project_warning_bytes: DEFAULT_PROJECT_WARNING_BYTES,
            failure_injector: None,
        }
    }
}

type RefState = Option<Vec<Option<(u64, u64, i64, i64, i64, i64)>>>;

struct SnapshotCache {
    head: String,
    tree_id: String,
    files: Vec<(String, Vec<u8>)>,
    ref_state: RefState,
}

/// The process side of the writer lock: one owner thread at a time, which
/// may re-enter; the outermost entry also holds the cross-process `flock`.
#[derive(Default)]
struct ProcessLock {
    state: Mutex<(Option<ThreadId>, usize, Option<File>)>,
    released: Condvar,
}

static PROCESS_LOCKS: LazyLock<Mutex<HashMap<PathBuf, Arc<ProcessLock>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

struct WriterGuard {
    lock: Arc<ProcessLock>,
}

impl Drop for WriterGuard {
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

fn random_hex() -> String {
    let mut bytes = [0u8; 16];
    let read = File::open("/dev/urandom").and_then(|mut source| source.read_exact(&mut bytes));
    if read.is_err() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        bytes = (nanos ^ (u128::from(std::process::id()) << 64)).to_le_bytes();
    }
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn is_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink())
}

/// `path.read_text(encoding="utf-8")`: universal newlines, strict UTF-8.
fn read_text(path: &Path) -> std::io::Result<std::result::Result<String, Error>> {
    let bytes = fs::read(path)?;
    Ok(pystr::decode_utf8(&bytes).map(pystr::universal_newlines))
}

/// `json.loads(path.read_text())` where only `OSError` and
/// `JSONDecodeError` are tolerated, as `None`.
fn read_json(path: &Path) -> Result<Option<Value>> {
    match read_text(path) {
        Err(_) => Ok(None),
        Ok(Err(error)) => Err(error),
        Ok(Ok(text)) => Ok(json::parse(&text)),
    }
}

/// `PurePosixPath(path).parts` for a relative path.
fn parts(path: &str) -> Vec<&str> {
    path.split('/')
        .filter(|part| !part.is_empty() && *part != ".")
        .collect()
}

/// `PurePosixPath(path).name`.
fn name_of(path: &str) -> &str {
    parts(path).last().copied().unwrap_or("")
}

/// `PurePosixPath(path).stem`.
fn stem_of(path: &str) -> &str {
    let name = name_of(path);
    match name.rfind('.') {
        Some(index) if !name[..index].trim_start_matches('.').is_empty() => &name[..index],
        _ => name,
    }
}

/// `PurePosixPath(path).suffix.lower()`.
fn suffix_of(path: &str) -> String {
    let name = name_of(path).trim_start_matches('.');
    name.rfind('.')
        .map(|index| name[index..].to_lowercase())
        .unwrap_or_default()
}

fn utc_now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64)
}

/// `ArtifactStore`.
pub struct ArtifactStore {
    pub repo_path: PathBuf,
    pub project_id: String,
    pub state_root: PathBuf,
    pub enabled: bool,
    pub artifact_ref: String,
    pub project_warning_bytes: u64,
    pub project_state: PathBuf,
    pub lock_path: PathBuf,
    pub metadata_path: PathBuf,
    pub journal_path: PathBuf,
    pub history_verification_path: PathBuf,
    pub materialized_path: PathBuf,
    failure_injector: Option<FailureInjector>,
    snapshot_cache: Mutex<Option<SnapshotCache>>,
}

impl ArtifactStore {
    pub fn open(
        repo_path: &Path,
        project_id: &str,
        state_root: &Path,
        options: StoreOptions,
    ) -> Result<Self> {
        let repo_path = PathBuf::from(paths::resolve(&repo_path.to_string_lossy()));
        let state_root = PathBuf::from(paths::resolve(&state_root.to_string_lossy()));
        let project_id = validate_identity(project_id, "project ID")?.to_string();
        if options.artifact_ref != ARTIFACT_REF {
            return Err(validation(format!(
                "unsupported artifact ref {}; expected {ARTIFACT_REF}",
                pystr::repr(&options.artifact_ref)
            )));
        }
        let project_state = state_root.join("artifacts").join(&project_id);
        Ok(Self {
            lock_path: state_root.join("locks").join(format!("{project_id}.lock")),
            metadata_path: project_state.join("materialization.json"),
            journal_path: project_state.join("materialization-journal.json"),
            history_verification_path: project_state.join("history-verification.json"),
            materialized_path: repo_path.join(".orchestrator"),
            project_state,
            repo_path,
            project_id,
            state_root,
            enabled: options.enabled,
            artifact_ref: options.artifact_ref,
            project_warning_bytes: options.project_warning_bytes,
            failure_injector: options.failure_injector,
            snapshot_cache: Mutex::new(None),
        })
    }

    /// `initialize`: create the orphan ref, or adopt a verified existing one.
    pub fn initialize(&self, device_id: &str, actor_type: &str) -> Result<WriteResult> {
        self.require_enabled()?;
        validate_actor(actor_type)?;
        validate_event_id(device_id, "device ID")?;
        self.with_writer_lock(|| {
            self.verify_repository()?;
            self.recover_materialization_transaction()?;
            let event_id = format!("initialize:{}", self.project_id);
            if let Some(head) = self.head()? {
                self.validate_artifact_head(&head)?;
                self.ensure_materialization_consistent(&head)?;
                self.materialize(&head, false)?;
                return Ok(WriteResult {
                    event_id,
                    tree_id: self.tree_id(&head)?,
                    commit_id: head.clone(),
                    base_commit: Some(head),
                    idempotent: true,
                    warnings: Vec::new(),
                });
            }
            if self.materialized_path.exists() || is_symlink(&self.materialized_path) {
                return Err(conflict(
                    "cannot initialize over an existing .orchestrator tree; use the journaled legacy migration",
                ));
            }
            let mut event = Mutation::new(
                &event_id,
                actor_type,
                device_id,
                vec![Operation::ConfigWrite {
                    content: self.render_initial_config(),
                }],
            );
            event.summary = "Initialize Relay artifact store".to_string();
            self.commit_mutation(&event, None, None, true)
        })
    }

    /// `mutate`: commit one event, or return the commit an identical event
    /// already made.
    pub fn mutate(&self, mutation: &Mutation) -> Result<WriteResult> {
        self.require_enabled()?;
        validate_mutation_envelope(mutation)?;
        self.with_writer_lock(|| {
            self.verify_repository()?;
            self.recover_materialization_transaction()?;
            let head = self
                .head()?
                .ok_or_else(|| validation("artifact store is not initialized"))?;
            self.validate_artifact_head(&head)?;
            let digest = mutation_digest(mutation);
            if let Some((prior_commit, prior_digest)) = self.find_event(&mutation.event_id)? {
                if prior_digest != digest {
                    return Err(Error::new(
                        ErrorKind::EventCollision,
                        format!(
                            "event ID {} was already committed with different content",
                            pystr::repr(&mutation.event_id)
                        ),
                    ));
                }
                self.materialize(&head, false)?;
                return Ok(WriteResult {
                    event_id: mutation.event_id.clone(),
                    tree_id: self.tree_id(&prior_commit)?,
                    base_commit: self.first_parent(&prior_commit)?,
                    commit_id: prior_commit,
                    idempotent: true,
                    warnings: Vec::new(),
                });
            }
            if let Some(expected) = &mutation.expected_base
                && *expected != head
            {
                return Err(Error::new(
                    ErrorKind::ConcurrentUpdate,
                    format!("artifact base changed: expected {expected}, found {head}"),
                ));
            }
            self.ensure_materialization_consistent(&head)?;
            self.commit_mutation(mutation, Some(&head), Some(&digest), true)
        })
    }

    /// `prepare_mutation`: build the commit without advancing the ref, for a
    /// caller that publishes it later by compare-and-swap.
    pub fn prepare_mutation(&self, mutation: &Mutation) -> Result<WriteResult> {
        self.require_enabled()?;
        validate_mutation_envelope(mutation)?;
        self.with_writer_lock(|| {
            self.verify_repository()?;
            self.recover_materialization_transaction()?;
            let head = self
                .head()?
                .ok_or_else(|| validation("artifact store is not initialized"))?;
            self.validate_artifact_head(&head)?;
            if mutation.expected_base.as_deref() != Some(head.as_str()) {
                return Err(Error::new(
                    ErrorKind::ConcurrentUpdate,
                    format!(
                        "prepared artifact base changed: expected {}, found {head}",
                        mutation.expected_base.as_deref().unwrap_or("None")
                    ),
                ));
            }
            self.ensure_materialization_consistent(&head)?;
            self.build_mutation_commit(mutation, Some(&head), &mutation_digest(mutation))
        })
    }

    /// `bootstrap_legacy`: publish a reviewed legacy import as the orphan
    /// root, leaving the existing `.orchestrator` directory untouched.
    pub fn bootstrap_legacy(&self, mutation: &Mutation) -> Result<WriteResult> {
        self.require_enabled()?;
        validate_mutation_envelope(mutation)?;
        if mutation.actor_type != "migration" || mutation.expected_base.is_some() {
            return Err(validation(
                "legacy bootstrap requires migration ownership and an absent base",
            ));
        }
        self.with_writer_lock(|| {
            self.verify_repository()?;
            self.recover_materialization_transaction()?;
            if is_symlink(&self.materialized_path) || !self.materialized_path.is_dir() {
                return Err(conflict(
                    "legacy bootstrap requires a normal existing .orchestrator directory",
                ));
            }
            let head = self.head()?;
            let digest = mutation_digest(mutation);
            if let Some(head) = head {
                self.validate_artifact_head(&head)?;
                let Some((prior_commit, prior_digest)) = self.find_event(&mutation.event_id)?
                else {
                    return Err(Error::new(
                        ErrorKind::ConcurrentUpdate,
                        "artifact ref appeared before legacy bootstrap; review it explicitly",
                    ));
                };
                if prior_digest != digest {
                    return Err(Error::new(
                        ErrorKind::EventCollision,
                        format!(
                            "event ID {} was already committed with different content",
                            pystr::repr(&mutation.event_id)
                        ),
                    ));
                }
                return Ok(WriteResult {
                    event_id: mutation.event_id.clone(),
                    tree_id: self.tree_id(&prior_commit)?,
                    base_commit: self.first_parent(&prior_commit)?,
                    commit_id: prior_commit,
                    idempotent: true,
                    warnings: Vec::new(),
                });
            }
            self.commit_mutation(mutation, None, Some(&digest), false)
        })
    }

    /// `recover`: rebuild the projection from the ref after an interruption.
    pub fn recover(&self) -> Result<String> {
        self.require_enabled()?;
        self.with_writer_lock(|| {
            self.verify_repository()?;
            self.recover_materialization_transaction()?;
            let head = self
                .head()?
                .ok_or_else(|| validation("artifact store is not initialized"))?;
            self.validate_artifact_head(&head)?;
            self.materialize(&head, true)?;
            Ok(head)
        })
    }

    /// `snapshot`: the files of one immutable head, read without the writer
    /// lock. The head is reused while the ref's storage files keep their
    /// identity, and a head's files are read once (RR-440).
    pub fn snapshot(&self) -> Result<Snapshot> {
        self.require_enabled()?;
        let ref_state = self.ref_storage_state();
        let cached_head = {
            let cache = self
                .snapshot_cache
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            match (&ref_state, cache.as_ref()) {
                (Some(_), Some(cached)) if cached.ref_state == ref_state => {
                    Some(cached.head.clone())
                }
                _ => None,
            }
        };
        let head = match cached_head {
            Some(head) => head,
            None => self
                .head()?
                .ok_or_else(|| validation("artifact store is not initialized"))?,
        };
        self.validate_artifact_head(&head)?;
        let mut cache = self
            .snapshot_cache
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if cache.as_ref().is_none_or(|cached| cached.head != head) {
            let entries = self.tree_entries(Some(&head))?;
            let blobs = self.cat_blobs(entries.iter().map(|(_, entry)| entry.oid.as_str()))?;
            let files = entries
                .iter()
                .map(|(path, entry)| (path.clone(), blobs[&entry.oid].clone()))
                .collect();
            *cache = Some(SnapshotCache {
                tree_id: self.tree_id(&head)?,
                head: head.clone(),
                files,
                ref_state,
            });
        } else if let Some(cached) = cache.as_mut() {
            cached.ref_state = ref_state;
        }
        let cached = cache.as_ref().expect("filled above");
        Ok(Snapshot {
            project_id: self.project_id.clone(),
            commit_id: head,
            tree_id: cached.tree_id.clone(),
            files: cached.files.clone(),
        })
    }

    fn commit_mutation(
        &self,
        mutation: &Mutation,
        current_head: Option<&str>,
        digest: Option<&str>,
        materialize: bool,
    ) -> Result<WriteResult> {
        let digest = digest.map_or_else(|| mutation_digest(mutation), str::to_string);
        let prepared = self.build_mutation_commit(mutation, current_head, &digest)?;
        self.inject("during_cas")?;
        let expected = match current_head {
            Some(head) => head.to_string(),
            None => self.zero_oid()?,
        };
        let update = self.git(
            &[
                "update-ref",
                &self.artifact_ref,
                &prepared.commit_id,
                &expected,
            ],
            &[],
            None,
            &[0, 128],
        )?;
        if update.status != 0 {
            let found = self.head()?.unwrap_or_else(|| "missing".to_string());
            return Err(Error::new(
                ErrorKind::ConcurrentUpdate,
                format!("artifact ref CAS failed: expected {expected}, found {found}"),
            ));
        }
        self.inject("after_ref_update")?;
        if materialize {
            self.materialize(&prepared.commit_id, false)?;
        }
        Ok(prepared)
    }

    fn build_mutation_commit(
        &self,
        mutation: &Mutation,
        current_head: Option<&str>,
        digest: &str,
    ) -> Result<WriteResult> {
        let entries = self.tree_entries(current_head)?;
        let (prepared, warnings) = self.prepare_operations(&mutation.operations, &entries)?;
        self.inject("before_commit")?;
        let temporary = std::env::temp_dir().join(format!("relay-artifact-index-{}", random_hex()));
        fs::DirBuilder::new().mode(0o700).create(&temporary)?;
        let result = (|| {
            let index = temporary.join("index");
            let index = index.to_string_lossy().into_owned();
            let env = [("GIT_INDEX_FILE", index.as_str())];
            match current_head {
                Some(head) => self.git(&["read-tree", head], &env, None, &[0])?,
                None => self.git(&["read-tree", "--empty"], &env, None, &[0])?,
            };
            for (path, content) in &prepared {
                match content {
                    None => {
                        self.git(
                            &["update-index", "--force-remove", "--", path],
                            &env,
                            None,
                            &[0],
                        )?;
                    }
                    Some(content) => {
                        let blob = self
                            .git(&["hash-object", "-w", "--stdin"], &[], Some(content), &[0])?
                            .line();
                        self.git(
                            &[
                                "update-index",
                                "--add",
                                "--cacheinfo",
                                "100644",
                                &blob,
                                path,
                            ],
                            &env,
                            None,
                            &[0],
                        )?;
                    }
                }
            }
            let tree_id = self.git(&["write-tree"], &env, None, &[0])?.line();
            self.validate_note_catalog_entries(&self.tree_entries(Some(&tree_id))?)?;
            let message = self.commit_message(mutation, digest);
            let mut arguments = vec!["commit-tree", tree_id.as_str()];
            if let Some(head) = current_head {
                arguments.extend(["-p", head]);
            }
            let commit_id = self
                .git(&arguments, &[], Some(message.as_bytes()), &[0])?
                .line();
            Ok(WriteResult {
                event_id: mutation.event_id.clone(),
                commit_id,
                tree_id,
                base_commit: current_head.map(str::to_string),
                idempotent: false,
                warnings: warnings.clone(),
            })
        })();
        let _ = fs::remove_dir_all(&temporary);
        result
    }

    /// `_prepare_operations`: each operation's path and new bytes (`None` to
    /// delete), validated, with the attachment budget warnings.
    fn prepare_operations(
        &self,
        operations: &[Operation],
        entries: &Entries,
    ) -> Result<(Prepared, Vec<String>)> {
        if operations.is_empty() {
            return Err(validation(
                "an artifact event must contain at least one operation",
            ));
        }
        let mut prepared: Prepared = Vec::new();
        // Insertion-ordered like the Python dict: per-ticket totals and the
        // first ticket over budget follow this order.
        let mut projected_sizes: Vec<(String, u64)> = Vec::new();
        for (path, entry) in entries {
            if path.starts_with(".orchestrator/attachments/") {
                projected_sizes.push((path.clone(), self.blob_size(&entry.oid)?));
            }
        }
        let set_size = |sizes: &mut Vec<(String, u64)>, path: &str, size: Option<u64>| {
            let position = sizes.iter().position(|(name, _)| name == path);
            match (position, size) {
                (Some(index), Some(size)) => sizes[index].1 = size,
                (None, Some(size)) => sizes.push((path.to_string(), size)),
                (Some(index), None) => {
                    sizes.remove(index);
                }
                (None, None) => {}
            }
        };
        for operation in operations {
            match operation {
                Operation::TicketWrite {
                    ticket_id,
                    artifact_id,
                    markdown,
                } => {
                    let ticket_id = validate_ticket_id(ticket_id)?;
                    let artifact_id = validate_artifact_id(artifact_id)?;
                    let content = prepare_ticket_markdown(ticket_id, artifact_id, markdown)?;
                    reject_secrets(&content, &format!("ticket {ticket_id}"))?;
                    if content.len() > TICKET_MAX_BYTES {
                        return Err(validation(format!(
                            "ticket {ticket_id} is {} bytes; limit is {TICKET_MAX_BYTES}",
                            content.len()
                        )));
                    }
                    prepared.push((format!(".orchestrator/{ticket_id}.md"), Some(content)));
                }
                Operation::TicketDelete { ticket_id } => {
                    let ticket_id = validate_ticket_id(ticket_id)?;
                    prepared.push((format!(".orchestrator/{ticket_id}.md"), None));
                    let prefix = format!(".orchestrator/attachments/{ticket_id}/");
                    let mut existing: Vec<&String> = entries.iter().map(|(path, _)| path).collect();
                    existing.sort();
                    for path in existing {
                        if path.starts_with(&prefix) {
                            prepared.push((path.clone(), None));
                            set_size(&mut projected_sizes, path, None);
                        }
                    }
                }
                Operation::NoteWrite {
                    note_id,
                    artifact_id,
                    project_id,
                    markdown,
                } => {
                    let note_id = validate_note_id(note_id)?;
                    let artifact_id = validate_artifact_id(artifact_id)?;
                    if *project_id != self.project_id {
                        return Err(identity_error("note project_id does not match the store"));
                    }
                    let content =
                        prepare_note_markdown(note_id, artifact_id, &self.project_id, markdown)?;
                    if content.len() > NOTE_MAX_BYTES {
                        return Err(validation(format!(
                            "note {note_id} is {} bytes; limit is {NOTE_MAX_BYTES}",
                            content.len()
                        )));
                    }
                    reject_note_private_runtime(&content, note_id)?;
                    let path = format!(".orchestrator/notes/{note_id}.md");
                    if let Some(existing) = entry(entries, &path) {
                        let prior = read_note_document(&self.cat_blob(&existing.oid)?, note_id)?;
                        if prior.identity.artifact_id != artifact_id {
                            return Err(identity_error(format!(
                                "note {note_id} already belongs to immutable artifact {}",
                                pystr::repr(&prior.identity.artifact_id)
                            )));
                        }
                    }
                    reject_secrets(&content, &format!("note {note_id}"))?;
                    prepared.push((path, Some(content)));
                }
                Operation::NoteDelete {
                    note_id,
                    artifact_id,
                } => {
                    let note_id = validate_note_id(note_id)?;
                    let artifact_id = validate_artifact_id(artifact_id)?;
                    let path = format!(".orchestrator/notes/{note_id}.md");
                    let Some(existing) = entry(entries, &path) else {
                        return Err(validation(format!("note {note_id} is not materialized")));
                    };
                    let prior = read_note_document(&self.cat_blob(&existing.oid)?, note_id)?;
                    if prior.identity.artifact_id != artifact_id {
                        return Err(identity_error(format!(
                            "note {note_id} immutable artifact_id does not match delete request"
                        )));
                    }
                    prepared.push((path, None));
                }
                Operation::NoteIndexWrite { content } => {
                    validate_note_index(content, &self.project_id)?;
                    reject_secrets(content, "note index")?;
                    prepared.push((
                        ".orchestrator/note-index.jsonl".to_string(),
                        Some(content.clone()),
                    ));
                }
                Operation::AttachmentWrite {
                    ticket_id,
                    filename,
                    mime_type,
                    content,
                } => {
                    let ticket_id = validate_ticket_id(ticket_id)?;
                    let filename = validate_filename(filename)?;
                    validate_attachment(filename, mime_type, content)?;
                    let path = format!(".orchestrator/attachments/{ticket_id}/{filename}");
                    set_size(&mut projected_sizes, &path, Some(content.len() as u64));
                    prepared.push((path, Some(content.clone())));
                }
                Operation::AttachmentDelete {
                    ticket_id,
                    filename,
                } => {
                    let ticket_id = validate_ticket_id(ticket_id)?;
                    let filename = validate_filename(filename)?;
                    let path = format!(".orchestrator/attachments/{ticket_id}/{filename}");
                    set_size(&mut projected_sizes, &path, None);
                    prepared.push((path, None));
                }
                Operation::ConfigWrite { content } => {
                    self.validate_config(content)?;
                    reject_secrets(content, "artifact config")?;
                    prepared.push((
                        ".orchestrator/config.toml".to_string(),
                        Some(content.clone()),
                    ));
                }
                Operation::ArchiveIndexWrite { content } => {
                    validate_archive_index(content)?;
                    reject_secrets(content, "archive index")?;
                    prepared.push((
                        ".orchestrator/archive-index.jsonl".to_string(),
                        Some(content.clone()),
                    ));
                }
                Operation::ProgramEventWrite { event_id, content } => {
                    let event_id = validate_event_id(event_id, "Program event ID")?;
                    let content = self.prepare_program_event(event_id, content)?;
                    let path = format!(".orchestrator/program/events/{event_id}.json");
                    if let Some(existing) = entry(entries, &path)
                        && self.cat_blob(&existing.oid)? != content
                    {
                        return Err(Error::new(
                            ErrorKind::EventCollision,
                            format!(
                                "immutable Program event {} already exists with different content",
                                pystr::repr(event_id)
                            ),
                        ));
                    }
                    prepared.push((path, Some(content)));
                }
            }
        }
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        for (path, _) in &prepared {
            validate_allowlisted_path(path)?;
            if !seen.insert(path) {
                return Err(validation(format!(
                    "event modifies artifact path more than once: {path}"
                )));
            }
        }
        let mut ticket_totals: Vec<(String, u64)> = Vec::new();
        for (path, size) in &projected_sizes {
            let ticket = path.split('/').nth(2).unwrap_or_default().to_string();
            match ticket_totals.iter_mut().find(|(name, _)| *name == ticket) {
                Some(total) => total.1 += size,
                None => ticket_totals.push((ticket, *size)),
            }
        }
        for (ticket, total) in &ticket_totals {
            if *total > ATTACHMENT_TICKET_MAX_BYTES {
                return Err(validation(format!(
                    "attachments for {ticket} total {total} bytes; limit is {ATTACHMENT_TICKET_MAX_BYTES}"
                )));
            }
        }
        let project_total: u64 = projected_sizes.iter().map(|(_, size)| size).sum();
        let mut warnings = Vec::new();
        if project_total > self.project_warning_bytes {
            warnings.push(format!(
                "project attachment total {project_total} exceeds warning budget {}",
                self.project_warning_bytes
            ));
        }
        Ok((prepared, warnings))
    }

    /// `_prepare_program_event`: the event's canonical JSON bytes.
    pub fn prepare_program_event(&self, event_id: &str, content: &[u8]) -> Result<Vec<u8>> {
        if content.len() > PROGRAM_EVENT_MAX_BYTES {
            return Err(validation(format!(
                "Program event is {} bytes; limit is {PROGRAM_EVENT_MAX_BYTES}",
                content.len()
            )));
        }
        let text = decode_json_bytes(content)
            .ok_or_else(|| validation("Program event is not valid UTF-8 JSON: Expecting value"))?;
        let payload = json::parse(&text)
            .ok_or_else(|| validation("Program event is not valid UTF-8 JSON: Expecting value"))?;
        let Value::Dict(dict) = &payload else {
            return Err(validation("Program event must be a JSON object"));
        };
        if !dict
            .get("event_id")
            .is_some_and(|value| value.is_str(event_id))
        {
            return Err(validation(
                "Program event_id does not match its typed operation",
            ));
        }
        if !dict
            .get("project_id")
            .is_some_and(|value| value.is_str(&self.project_id))
        {
            return Err(identity_error(
                "Program event project_id does not match the store",
            ));
        }
        let forbidden = find_forbidden_keys(&payload);
        if !forbidden.is_empty() {
            return Err(validation(format!(
                "Program event contains prohibited Git content: {}",
                forbidden.into_iter().collect::<Vec<_>>().join(", ")
            )));
        }
        if json::parse_strict(&text).is_none() {
            return Err(Error::value(
                "'utf-8' codec can't encode character: surrogates not allowed",
            ));
        }
        let encoded = (json::dumps_compact_sorted_unicode(&payload) + "\n").into_bytes();
        reject_secrets(&encoded, &format!("Program event {event_id}"))?;
        Ok(encoded)
    }

    fn commit_message(&self, mutation: &Mutation, digest: &str) -> String {
        let summary = pystr::strip(&mutation.summary);
        let summary = if summary.is_empty() {
            "Relay artifact mutation"
        } else {
            summary
        };
        let mut lines = vec![
            summary.to_string(),
            String::new(),
            format!("Relay-Project-ID: {}", self.project_id),
            format!("Relay-Event-ID: {}", mutation.event_id),
            format!("Relay-Event-Digest: {digest}"),
            format!("Relay-Device-ID: {}", mutation.device_id),
            format!("Relay-Actor-Type: {}", mutation.actor_type),
        ];
        if let Some(provider) = mutation
            .provider
            .as_deref()
            .filter(|provider| !provider.is_empty())
        {
            lines.push(format!("Relay-Provider: {provider}"));
        }
        lines.join("\n") + "\n"
    }

    /// `_find_event`: the commit and digest that recorded `event_id`, from
    /// its own trailers or a sync resolution's `Relay-Resolved-Event` line.
    pub fn find_event(&self, event_id: &str) -> Result<Option<(String, String)>> {
        if self.head()?.is_none() {
            return Ok(None);
        }
        let output = self
            .git(
                &["log", "--format=%H%x1f%B%x1e", &self.artifact_ref],
                &[],
                None,
                &[0],
            )?
            .text();
        for record in output.split('\u{1e}') {
            if !record.contains('\u{1f}') {
                continue;
            }
            let Some((commit_id, body)) = pystr::strip(record).split_once('\u{1f}') else {
                // Python's tuple unpacking would raise ValueError here.
                return Err(Error::value(
                    "not enough values to unpack (expected 2, got 1)",
                ));
            };
            let trailers = parse_trailers(body);
            if trailers.get("Relay-Event-ID").map(String::as_str) == Some(event_id) {
                let digest = trailers
                    .get("Relay-Event-Digest")
                    .filter(|digest| !digest.is_empty())
                    .ok_or_else(|| {
                        validation(format!(
                            "existing event {} lacks its immutable digest",
                            pystr::repr(event_id)
                        ))
                    })?;
                return Ok(Some((commit_id.to_string(), digest.clone())));
            }
            for line in pystr::splitlines(body) {
                let Some(resolved) = line.strip_prefix("Relay-Resolved-Event: ") else {
                    continue;
                };
                if let Some((resolved_id, digest)) = resolved.split_once(' ')
                    && resolved_id == event_id
                {
                    return Ok(Some((commit_id.to_string(), digest.to_string())));
                }
            }
        }
        Ok(None)
    }

    /// `_validate_artifact_head`: the ref must be an orphan, linear history
    /// of allowlisted, valid files. History already verified (recorded in
    /// `history-verification.json`) is not checked again.
    pub fn validate_artifact_head(&self, head: &str) -> Result<()> {
        let mut cached_head: Option<String> = None;
        if let Some(Value::Dict(cache)) = read_json(&self.history_verification_path)?
            && cache
                .get("project_id")
                .is_some_and(|id| id.is_str(&self.project_id))
        {
            match cache.get("commit_id") {
                Some(Value::Str(candidate)) if candidate == head => {
                    cached_head = Some(candidate.clone())
                }
                Some(Value::Str(candidate)) => {
                    let ancestor = self.git(
                        &["merge-base", "--is-ancestor", candidate, head],
                        &[],
                        None,
                        &[0, 1, 128],
                    )?;
                    if ancestor.status == 0 {
                        cached_head = Some(candidate.clone());
                    }
                }
                _ => {}
            }
        }
        if cached_head.as_deref() == Some(head) {
            return Ok(());
        }
        let history: Vec<Vec<String>> = match &cached_head {
            Some(cached) => {
                let range = format!("{cached}..{head}");
                let history = self.rev_list_parents(&range)?;
                let mut expected_parent = cached.clone();
                for line in &history {
                    if line.len() != 2 || line[1] != expected_parent {
                        return Err(validation(
                            "artifact history must remain a linear descendant of its verified head",
                        ));
                    }
                    expected_parent = line[0].clone();
                }
                history
            }
            None => {
                let history = self.rev_list_parents(head)?;
                if history.first().is_none_or(|first| first.len() != 1) {
                    return Err(validation(
                        "artifact ref is not orphan-rooted; source history must never be reachable from it",
                    ));
                }
                let mut expected_parent = history[0][0].clone();
                for line in &history[1..] {
                    if line.len() != 2 || line[1] != expected_parent {
                        return Err(validation(
                            "artifact history must be linear and cannot contain merge parents",
                        ));
                    }
                    expected_parent = line[0].clone();
                }
                history
            }
        };
        let verified_entries = self.tree_entries(cached_head.as_deref())?;
        let mut entries = verified_entries.clone();
        for line in &history {
            let next_entries = self.tree_entries(Some(&line[0]))?;
            for (path, next) in &next_entries {
                if entry(&entries, path) == Some(next) {
                    continue;
                }
                validate_allowlisted_path(&next.path)?;
                if next.mode != "100644" || next.kind != "blob" {
                    return Err(validation(format!(
                        "artifact tree contains unsupported {} {}: {}",
                        next.mode, next.kind, next.path
                    )));
                }
            }
            entries = next_entries;
        }
        let Some(config_entry) = entry(&entries, ".orchestrator/config.toml").cloned() else {
            return Err(validation("artifact tree has no .orchestrator/config.toml"));
        };
        let mut all_paths: BTreeSet<&str> = entries.iter().map(|(path, _)| path.as_str()).collect();
        all_paths.extend(verified_entries.iter().map(|(path, _)| path.as_str()));
        let changed: Vec<&str> = all_paths
            .into_iter()
            .filter(|path| entry(&entries, path) != entry(&verified_entries, path))
            .collect();
        if changed.contains(&".orchestrator/config.toml") {
            self.validate_config(&self.cat_blob(&config_entry.oid)?)?;
        }
        let present: Vec<&TreeEntry> = changed
            .iter()
            .filter_map(|path| entry(&entries, path))
            .collect();
        let blobs = self.cat_blobs(present.iter().map(|entry| entry.oid.as_str()))?;
        for present in &present {
            self.validate_content_for_path(&present.path, &blobs[&present.oid])?;
        }
        if cached_head.is_none()
            || changed.iter().any(|path| {
                *path == ".orchestrator/note-index.jsonl"
                    || path.starts_with(".orchestrator/notes/")
            })
        {
            self.validate_note_catalog_entries(&entries)?;
        }
        let mut record = Dict::new();
        record.insert("version", 1);
        record.insert("project_id", self.project_id.as_str());
        record.insert("commit_id", head);
        self.write_json_atomic(&self.history_verification_path, &record)
    }

    fn rev_list_parents(&self, range: &str) -> Result<Vec<Vec<String>>> {
        Ok(self
            .git(
                &["rev-list", "--reverse", "--parents", range],
                &[],
                None,
                &[0],
            )?
            .text()
            .lines()
            .map(|line| line.split_whitespace().map(str::to_string).collect())
            .collect())
    }

    /// `_validate_content_for_path`: bytes selected by sync or conflict
    /// resolution, checked as a commit would check them.
    pub fn validate_content_for_path(&self, path: &str, content: &[u8]) -> Result<()> {
        validate_allowlisted_path(path)?;
        if path == ".orchestrator/config.toml" {
            self.validate_config(content)?;
            return reject_secrets(content, "artifact config");
        }
        if path == ".orchestrator/archive-index.jsonl" {
            validate_archive_index(content)?;
            return reject_secrets(content, "archive index");
        }
        if path == ".orchestrator/note-index.jsonl" {
            validate_note_index(content, &self.project_id)?;
            return reject_secrets(content, "note index");
        }
        if path.starts_with(".orchestrator/notes/") {
            let note_id = stem_of(path);
            if content.len() > NOTE_MAX_BYTES {
                return Err(validation(format!(
                    "note {note_id} is {} bytes; limit is {NOTE_MAX_BYTES}",
                    content.len()
                )));
            }
            let document = read_note_document(content, note_id)?;
            let normalized = prepare_note_markdown(
                note_id,
                &document.identity.artifact_id,
                &self.project_id,
                content,
            )?;
            reject_secrets(&normalized, &format!("note {note_id}"))?;
            reject_note_private_runtime(&normalized, note_id)?;
            if normalized != content {
                return Err(validation(format!(
                    "note {note_id} is not in canonical artifact form"
                )));
            }
            return Ok(());
        }
        if path.starts_with(".orchestrator/attachments/") {
            let filename = name_of(path);
            let mime_type = attachment_mime_for_filename(filename)?;
            return validate_attachment(filename, mime_type, content);
        }
        if path.starts_with(".orchestrator/program/events/") {
            let event_id = stem_of(path);
            if self.prepare_program_event(event_id, content)? != content {
                return Err(validation(format!(
                    "Program event {event_id} is not in canonical artifact form"
                )));
            }
            return Ok(());
        }
        let ticket_id = stem_of(path);
        let Some(artifact_id) = ticket_front_matter_value(content, "artifact_id") else {
            return Err(validation(format!(
                "ticket {ticket_id} has no immutable artifact_id"
            )));
        };
        let normalized = prepare_ticket_markdown(ticket_id, &artifact_id, content)?;
        reject_secrets(&normalized, &format!("ticket {ticket_id}"))?;
        if normalized != content {
            return Err(validation(format!(
                "ticket {ticket_id} is not in canonical artifact form"
            )));
        }
        Ok(())
    }

    /// `_validate_note_catalog_entries`, reading the blobs in one batch.
    pub fn validate_note_catalog_entries(&self, entries: &Entries) -> Result<()> {
        let selected: Vec<(&str, &str)> = entries
            .iter()
            .filter(|(path, _)| {
                path == ".orchestrator/note-index.jsonl"
                    || (path.starts_with(".orchestrator/notes/") && path.ends_with(".md"))
            })
            .map(|(path, entry)| (path.as_str(), entry.oid.as_str()))
            .collect();
        let blobs = self.cat_blobs(selected.iter().map(|(_, oid)| *oid))?;
        let files: BTreeMap<String, Vec<u8>> = selected
            .iter()
            .map(|(path, oid)| (path.to_string(), blobs[*oid].clone()))
            .collect();
        self.validate_note_catalog_files(&files)
    }

    /// `_validate_note_catalog_files`: the index and the note documents must
    /// describe each other exactly.
    pub fn validate_note_catalog_files(&self, files: &BTreeMap<String, Vec<u8>>) -> Result<()> {
        let note_paths: BTreeMap<&str, &[u8]> = files
            .iter()
            .filter(|(path, _)| path.starts_with(".orchestrator/notes/") && path.ends_with(".md"))
            .map(|(path, content)| (path.as_str(), content.as_slice()))
            .collect();
        let Some(index_content) = files.get(".orchestrator/note-index.jsonl") else {
            if !note_paths.is_empty() {
                return Err(validation("note documents require the typed note index"));
            }
            return Ok(());
        };
        let catalog = notes::decode_note_index(index_content, &self.project_id)
            .map_err(|error| recast_contract(error, ErrorKind::Validation))?;
        let mut active: BTreeSet<String> = BTreeSet::new();
        for (artifact_id, catalog_entry) in &catalog {
            let path = catalog_entry
                .get("path")
                .map(Value::py_str)
                .unwrap_or_default();
            if matches!(catalog_entry.get("materialized"), Some(Value::Bool(false))) {
                if note_paths.contains_key(path.as_str()) {
                    return Err(validation(format!(
                        "archived note remains materialized despite its catalog state: {path}"
                    )));
                }
                continue;
            }
            let Some(content) = note_paths.get(path.as_str()) else {
                return Err(validation(format!(
                    "active note index entry has no Markdown: {path}"
                )));
            };
            active.insert(path.clone());
            let note_id = catalog_entry
                .get("note_id")
                .map(Value::py_str)
                .unwrap_or_default();
            let document = read_note_document(content, &note_id)?;
            let same = |key: &str, value: &str| {
                catalog_entry
                    .get(key)
                    .is_some_and(|found| found.is_str(value))
            };
            let count = Value::Int(document.update.segments.len() as i64);
            if !(same("note_id", &document.identity.note_id)
                && document.identity.artifact_id == *artifact_id
                && document.identity.project_id == self.project_id
                && same("created_at", &document.identity.created_at)
                && same("updated_at", &document.update.captured_at)
                && same("recording_state", &document.update.recording_state)
                && json::py_eq_optional(Some(&count), catalog_entry.get("segment_count")))
            {
                return Err(identity_error(format!(
                    "note index identity or checkpoint metadata disagrees with {path}"
                )));
            }
        }
        let unindexed: Vec<&str> = note_paths
            .keys()
            .filter(|path| !active.contains(**path))
            .copied()
            .collect();
        if !unindexed.is_empty() {
            return Err(validation(format!(
                "note documents are missing typed index entries: {}",
                unindexed.join(", ")
            )));
        }
        Ok(())
    }

    fn validate_config(&self, content: &[u8]) -> Result<()> {
        let document = toml::loads_bytes(content)
            .map_err(|error| validation(format!("artifact config is invalid TOML: {error}")))?;
        if !document
            .get("schema_version")
            .is_some_and(|value| value.equals_int(2))
        {
            return Err(validation("artifact config schema_version must be 2"));
        }
        let project = document.get("project_id");
        if project.and_then(toml::Value::as_str) != Some(self.project_id.as_str()) {
            return Err(identity_error(format!(
                "artifact ref belongs to project {}, not {}",
                project.map_or_else(|| "None".to_string(), toml::Value::py_repr),
                pystr::repr(&self.project_id)
            )));
        }
        if document.get("artifact_ref").and_then(toml::Value::as_str)
            != Some(self.artifact_ref.as_str())
        {
            return Err(validation(
                "artifact config uses an unexpected artifact_ref",
            ));
        }
        if !toml_in_set(
            document.get("remote_sync"),
            &["local_only", "enabled", "paused"],
        )? {
            return Err(validation("artifact config remote_sync is invalid"));
        }
        let lifecycle = document.get("artifact_lifecycle");
        if lifecycle.is_some() && !toml_in_set(lifecycle, &["legacy", "enabled"])? {
            return Err(validation("artifact config artifact_lifecycle is invalid"));
        }
        match document.get("next_note_id") {
            None => {}
            Some(toml::Value::Integer(value)) if *value > 0 => {}
            Some(toml::Value::BigInteger(digits)) if !digits.starts_with('-') => {}
            Some(_) => {
                return Err(validation(
                    "artifact config next_note_id must be a positive integer",
                ));
            }
        }
        Ok(())
    }

    fn render_initial_config(&self) -> Vec<u8> {
        let name = self
            .repo_path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let prefix: String = name
            .chars()
            .filter(char::is_ascii_alphanumeric)
            .collect::<String>()
            .to_ascii_uppercase()
            .chars()
            .take(3)
            .collect();
        let prefix = if prefix.is_empty() {
            "RR".to_string()
        } else {
            prefix
        };
        format!(
            "schema_version = 2\nproject_id = \"{}\"\nprefix = \"{prefix}\"\nartifact_ref = \"{}\"\n\
             remote_sync = \"local_only\"\nartifact_lifecycle = \"legacy\"\nnext_id = 1\nnext_note_id = 1\n",
            self.project_id, self.artifact_ref
        )
        .into_bytes()
    }

    /// `_ensure_materialization_consistent`: refuse to write over a manually
    /// edited projection, and refresh one the ref has moved past.
    pub fn ensure_materialization_consistent(&self, head: &str) -> Result<()> {
        let metadata = self.read_metadata()?;
        let target_exists = self.materialized_path.exists() || is_symlink(&self.materialized_path);
        let Some(metadata) = metadata else {
            if target_exists {
                return Err(conflict(
                    "existing .orchestrator has no verified artifact base; use explicit import or migration",
                ));
            }
            return Ok(());
        };
        if !target_exists {
            return self.materialize(head, true);
        }
        let expected = expected_materialized_sha256(&metadata);
        let actual = self.materialized_sha256()?;
        let manually_changed = !same_hashes(&expected, &actual);
        let ref_changed = !metadata
            .get("commit_id")
            .is_some_and(|commit| commit.is_str(head));
        if manually_changed && ref_changed {
            return Err(conflict(format!(
                "materialized files and artifact ref both changed from their shared base ({})",
                describe_materialization_difference(&expected, &actual)
            )));
        }
        if manually_changed {
            return Err(conflict(format!(
                "materialized .orchestrator was edited manually ({}); use explicit Save/import",
                describe_materialization_difference(&expected, &actual)
            )));
        }
        if ref_changed {
            self.materialize(head, true)?;
        }
        Ok(())
    }

    /// `_materialize`: replace the projection with the files of `head`,
    /// through a journaled rename that `recover` can finish or undo.
    pub fn materialize(&self, head: &str, force: bool) -> Result<()> {
        if !force
            && let Some(metadata) = self.read_metadata()?
            && metadata
                .get("commit_id")
                .is_some_and(|commit| commit.is_str(head))
            && self.materialized_path.exists()
            && same_hashes(
                &expected_materialized_sha256(&metadata),
                &self.materialized_sha256()?,
            )
        {
            return Ok(());
        }
        let entries = self.tree_entries(Some(head))?;
        self.validate_artifact_head(head)?;
        let blobs = self.cat_blobs(entries.iter().map(|(_, entry)| entry.oid.as_str()))?;
        let temp_root = self
            .repo_path
            .join(format!(".relay-materialization-{}", random_hex()));
        let backup_root = self
            .repo_path
            .join(format!(".relay-materialization-backup-{}", random_hex()));
        let mut journal = Dict::new();
        journal.insert("version", 1);
        journal.insert("head", head);
        journal.insert("temp", temp_root.to_string_lossy().into_owned());
        journal.insert("backup", backup_root.to_string_lossy().into_owned());
        journal.insert(
            "target",
            self.materialized_path.to_string_lossy().into_owned(),
        );
        fs::create_dir_all(&self.project_state)?;
        self.write_json_atomic(&self.journal_path, &journal)?;
        // On failure the journal stays, so the next writer can recover.
        fs::DirBuilder::new().mode(0o700).create(&temp_root)?;
        for (path, entry) in &entries {
            let relative = path.strip_prefix(".orchestrator/").unwrap_or(path);
            let destination = temp_root.join(relative);
            if let Some(parent) = destination.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::write(&destination, &blobs[&entry.oid])?;
            fs::set_permissions(&destination, fs::Permissions::from_mode(0o600))?;
        }
        self.inject("during_materialization")?;
        if is_symlink(&self.materialized_path) {
            return Err(conflict(
                ".orchestrator materialization target is a symlink",
            ));
        }
        if self.materialized_path.exists() {
            fs::rename(&self.materialized_path, &backup_root)?;
        }
        fs::rename(&temp_root, &self.materialized_path)?;
        self.install_local_exclude()?;
        let mut metadata = Dict::new();
        metadata.insert("version", 1);
        metadata.insert("project_id", self.project_id.as_str());
        metadata.insert("artifact_ref", self.artifact_ref.as_str());
        metadata.insert("commit_id", head);
        metadata.insert("tree_id", self.tree_id(head)?);
        let mut blobs_by_path: Vec<&(String, TreeEntry)> = entries.iter().collect();
        blobs_by_path.sort_by(|left, right| left.0.cmp(&right.0));
        let mut file_blobs = Dict::new();
        for (path, entry) in blobs_by_path {
            file_blobs.insert(path, entry.oid.as_str());
        }
        metadata.insert("file_blobs", file_blobs);
        let mut hashes = Dict::new();
        for (path, digest) in self.materialized_sha256()? {
            hashes.insert(&path, digest);
        }
        metadata.insert("sha256", hashes);
        metadata.insert("materialized_at", utc_now_seconds());
        self.write_json_atomic(&self.metadata_path, &metadata)?;
        if backup_root.exists() {
            fs::remove_dir_all(&backup_root)?;
        }
        remove_if_present(&self.journal_path)?;
        Ok(())
    }

    /// `_recover_materialization_transaction`: finish or undo a
    /// materialization a crash interrupted.
    pub fn recover_materialization_transaction(&self) -> Result<()> {
        if !self.journal_path.exists() {
            return Ok(());
        }
        let journal = match read_json(&self.journal_path) {
            Ok(Some(Value::Dict(journal))) => journal,
            _ => Dict::new(),
        };
        let temporary = self.journal_owned_path(journal.get("temp"));
        let backup = self.journal_owned_path(journal.get("backup"));
        if let Some(temporary) = &temporary
            && temporary.is_dir()
            && !is_symlink(temporary)
        {
            fs::remove_dir_all(temporary)?;
        }
        if let Some(backup) = &backup
            && backup.is_dir()
            && !is_symlink(backup)
            && !self.materialized_path.exists()
            && !is_symlink(&self.materialized_path)
        {
            fs::rename(backup, &self.materialized_path)?;
        }
        remove_if_present(&self.journal_path)?;
        if let Some(head) = self.head()? {
            self.materialize(&head, true)?;
        }
        if let Some(backup) = &backup
            && backup.is_dir()
            && !is_symlink(backup)
        {
            fs::remove_dir_all(backup)?;
        }
        Ok(())
    }

    fn journal_owned_path(&self, raw: Option<&Value>) -> Option<PathBuf> {
        let raw = raw?.as_str()?;
        let normalized = paths::normalize(raw);
        let (parent, name) = match normalized.rfind('/') {
            Some(0) => ("/", &normalized[1..]),
            Some(index) => (&normalized[..index], &normalized[index + 1..]),
            None => (".", normalized.as_str()),
        };
        (Path::new(parent) == self.repo_path && name.starts_with(".relay-materialization-"))
            .then(|| PathBuf::from(raw))
    }

    /// `_materialized_sha256`: the SHA-256 of every projection file, by
    /// path, skipping Finder metadata; a link or special file is a conflict.
    fn materialized_sha256(&self) -> Result<BTreeMap<String, String>> {
        let root = &self.materialized_path;
        if is_symlink(root) {
            return Err(conflict(
                ".orchestrator materialization target is a symlink",
            ));
        }
        let mut result = BTreeMap::new();
        if !root.exists() {
            return Ok(result);
        }
        let mut pending = vec![root.clone()];
        while let Some(directory) = pending.pop() {
            let mut children: Vec<PathBuf> = fs::read_dir(&directory)?
                .map(|child| child.map(|child| child.path()))
                .collect::<std::io::Result<_>>()?;
            children.sort();
            for child in children {
                let name = child
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let link = is_symlink(&child);
                // os.walk lists a link to a directory with the directories.
                if child.is_dir() {
                    if link {
                        return Err(conflict(format!(
                            "materialized tree contains a symlink directory: {}",
                            child.display()
                        )));
                    }
                    if !is_ignored_materialization_name(&name) {
                        pending.push(child);
                    }
                    continue;
                }
                if link || !child.is_file() {
                    return Err(conflict(format!(
                        "materialized tree contains a non-regular file: {}",
                        child.display()
                    )));
                }
                if is_ignored_materialization_name(&name) {
                    continue;
                }
                let relative = child
                    .strip_prefix(root)
                    .expect("walked below the root")
                    .to_string_lossy()
                    .into_owned();
                result.insert(relative, hex_digest(&fs::read(&child)?));
            }
        }
        Ok(result)
    }

    fn install_local_exclude(&self) -> Result<()> {
        let mut exclude = PathBuf::from(
            self.git(
                &["rev-parse", "--git-path", "info/exclude"],
                &[],
                None,
                &[0],
            )?
            .line(),
        );
        if !exclude.is_absolute() {
            exclude = self.repo_path.join(exclude);
        }
        if let Some(parent) = exclude.parent() {
            fs::create_dir_all(parent)?;
        }
        let existing = if exclude.exists() {
            read_text(&exclude)??
        } else {
            String::new()
        };
        let pattern = "/.orchestrator/";
        if pystr::splitlines(&existing)
            .iter()
            .any(|line| pystr::strip(line) == pattern)
        {
            return Ok(());
        }
        let mut content = existing;
        if !content.is_empty() && !content.ends_with('\n') {
            content.push('\n');
        }
        content.push_str(pattern);
        content.push('\n');
        let file_name = exclude
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let temporary = exclude.with_file_name(format!("{file_name}.relay-{}.tmp", random_hex()));
        fs::write(&temporary, content)?;
        fs::rename(&temporary, &exclude)?;
        Ok(())
    }

    fn read_metadata(&self) -> Result<Option<Dict>> {
        Ok(match read_json(&self.metadata_path)? {
            Some(Value::Dict(metadata))
                if metadata
                    .get("project_id")
                    .is_some_and(|id| id.is_str(&self.project_id)) =>
            {
                Some(metadata)
            }
            _ => None,
        })
    }

    /// `_write_json_atomic`: compact, sorted JSON and a newline, renamed
    /// into place.
    pub fn write_json_atomic(&self, path: &Path, payload: &Dict) -> Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let file_name = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let temporary = path.with_file_name(format!("{file_name}.{}.tmp", random_hex()));
        fs::write(
            &temporary,
            json::dumps_compact_sorted(&Value::Dict(payload.clone())) + "\n",
        )?;
        fs::rename(&temporary, path)?;
        Ok(())
    }

    /// `_tree_entries`: every file of a commit or tree, by path.
    pub fn tree_entries(&self, commit: Option<&str>) -> Result<Entries> {
        let Some(commit) = commit.filter(|commit| !commit.is_empty()) else {
            return Ok(Vec::new());
        };
        let output = self.git(
            &["ls-tree", "-r", "-z", "--full-tree", commit],
            &[],
            None,
            &[0],
        )?;
        let mut result: Entries = Vec::new();
        for record in output.stdout.split(|byte| *byte == 0) {
            if record.is_empty() {
                continue;
            }
            let tab = record
                .iter()
                .position(|byte| *byte == b'\t')
                .ok_or_else(|| Error::value("not enough values to unpack (expected 2, got 1)"))?;
            let metadata = String::from_utf8_lossy(&record[..tab]).into_owned();
            let mut fields = metadata.splitn(3, ' ');
            let (Some(mode), Some(kind), Some(oid)) = (fields.next(), fields.next(), fields.next())
            else {
                return Err(Error::value("not enough values to unpack (expected 3)"));
            };
            let path = pystr::decode_utf8(&record[tab + 1..])?.to_string();
            let tree_entry = TreeEntry {
                mode: mode.to_string(),
                kind: kind.to_string(),
                oid: oid.to_string(),
                path: path.clone(),
            };
            match result.iter_mut().find(|(name, _)| *name == path) {
                Some(existing) => existing.1 = tree_entry,
                None => result.push((path, tree_entry)),
            }
        }
        Ok(result)
    }

    /// `_cat_blob`.
    pub fn cat_blob(&self, oid: &str) -> Result<Vec<u8>> {
        Ok(self
            .git(&["cat-file", "blob", oid], &[], None, &[0])?
            .stdout)
    }

    /// `_cat_blobs`: many blobs through one `git cat-file --batch`.
    pub fn cat_blobs<'o>(
        &self,
        oids: impl IntoIterator<Item = &'o str>,
    ) -> Result<HashMap<String, Vec<u8>>> {
        let mut wanted: Vec<&str> = Vec::new();
        for oid in oids {
            if !wanted.contains(&oid) {
                wanted.push(oid);
            }
        }
        let mut blobs = HashMap::new();
        if wanted.is_empty() {
            return Ok(blobs);
        }
        let input: String = wanted.iter().map(|oid| format!("{oid}\n")).collect();
        let output = self
            .git(&["cat-file", "--batch"], &[], Some(input.as_bytes()), &[0])?
            .stdout;
        let mut offset = 0;
        for oid in wanted {
            let unreadable = || {
                Error::new(
                    ErrorKind::Store,
                    format!("git cat-file --batch could not read blob {oid}"),
                )
            };
            let newline = output[offset..]
                .iter()
                .position(|byte| *byte == b'\n')
                .map(|index| offset + index)
                .ok_or_else(unreadable)?;
            let header = String::from_utf8_lossy(&output[offset..newline]).into_owned();
            let header: Vec<&str> = header.split_whitespace().collect();
            if header.len() != 3 || header[0] != oid || header[1] != "blob" {
                return Err(unreadable());
            }
            let size: usize = header[2].parse().map_err(|_| unreadable())?;
            let start = newline + 1;
            let end = start + size;
            if output.get(end) != Some(&b'\n') {
                return Err(Error::new(
                    ErrorKind::Store,
                    format!("git cat-file --batch truncated blob {oid}"),
                ));
            }
            blobs.insert(oid.to_string(), output[start..end].to_vec());
            offset = end + 1;
        }
        Ok(blobs)
    }

    /// `_blob_size`.
    pub fn blob_size(&self, oid: &str) -> Result<u64> {
        let size = self.git(&["cat-file", "-s", oid], &[], None, &[0])?.line();
        size.parse().map_err(|_| {
            Error::value(format!(
                "invalid literal for int() with base 10: {}",
                pystr::repr(&size)
            ))
        })
    }

    /// `_tree_id`.
    pub fn tree_id(&self, commit: &str) -> Result<String> {
        Ok(self
            .git(
                &["rev-parse", &format!("{commit}^{{tree}}")],
                &[],
                None,
                &[0],
            )?
            .line())
    }

    /// `_zero_oid`: the null object id of the repository's object format.
    pub fn zero_oid(&self) -> Result<String> {
        let format = self
            .git(&["rev-parse", "--show-object-format"], &[], None, &[0])?
            .line();
        Ok("0".repeat(if format == "sha256" { 64 } else { 40 }))
    }

    /// `_first_parent`.
    pub fn first_parent(&self, commit: &str) -> Result<Option<String>> {
        let value = self.git(
            &["rev-parse", "--verify", &format!("{commit}^")],
            &[],
            None,
            &[0, 128],
        )?;
        Ok((value.status == 0).then(|| value.line()))
    }

    /// `_ref_storage_state`: the identity of the files a plain `.git`
    /// directory stores the ref in, or `None` to resolve through Git.
    fn ref_storage_state(&self) -> RefState {
        let git_dir = self.repo_path.join(".git");
        if !git_dir.is_dir() || git_dir.join("reftable").exists() {
            return None;
        }
        let mut state = Vec::new();
        for path in [
            git_dir.join(&self.artifact_ref),
            git_dir.join("packed-refs"),
        ] {
            match fs::metadata(&path) {
                Ok(metadata) => state.push(Some((
                    metadata.ino(),
                    metadata.size(),
                    metadata.mtime(),
                    metadata.mtime_nsec(),
                    metadata.ctime(),
                    metadata.ctime_nsec(),
                ))),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => state.push(None),
                Err(_) => return None,
            }
        }
        Some(state)
    }

    /// `_head`: the ref's commit, or `None` before initialization.
    pub fn head(&self) -> Result<Option<String>> {
        let result = self.git(
            &["rev-parse", "--verify", &self.artifact_ref],
            &[],
            None,
            &[0, 128],
        )?;
        Ok((result.status == 0).then(|| result.line()))
    }

    fn verify_repository(&self) -> Result<()> {
        if !self.repo_path.is_dir() {
            return Err(validation(format!(
                "repository is unavailable: {}",
                self.repo_path.display()
            )));
        }
        let inside = self.git(
            &["rev-parse", "--is-inside-work-tree"],
            &[],
            None,
            &[0, 128],
        )?;
        if inside.status != 0 || inside.line() != "true" {
            return Err(validation(format!(
                "not a Git worktree: {}",
                self.repo_path.display()
            )));
        }
        if self
            .git(&["rev-parse", "--is-bare-repository"], &[], None, &[0])?
            .line()
            == "true"
        {
            return Err(validation(
                "bare repositories cannot materialize Relay artifacts",
            ));
        }
        Ok(())
    }

    /// `_writer_lock`: serializes writers to this project across threads
    /// and processes, Python's included. A thread that holds it may re-enter.
    pub fn with_writer_lock<T>(&self, work: impl FnOnce() -> Result<T>) -> Result<T> {
        if let Some(parent) = self.lock_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let lock = PROCESS_LOCKS
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
        let guard = WriterGuard { lock: lock.clone() };
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

    fn require_enabled(&self) -> Result<()> {
        if self.enabled {
            Ok(())
        } else {
            Err(Error::new(
                ErrorKind::StoreDisabled,
                "project artifact store is opt-in and is disabled for this project",
            ))
        }
    }

    fn inject(&self, stage: &str) -> Result<()> {
        match &self.failure_injector {
            Some(injector) => injector(stage),
            None => Ok(()),
        }
    }

    /// `_git_environment(additions)`.
    pub fn git_environment(
        &self,
        additions: &[(&str, &str)],
    ) -> Vec<(std::ffi::OsString, std::ffi::OsString)> {
        git::environment(additions)
    }

    /// `_git`: `git -C <repo> <arguments>`, failing outside `allowed`.
    pub fn git(
        &self,
        arguments: &[&str],
        environment: &[(&str, &str)],
        input: Option<&[u8]>,
        allowed: &[i32],
    ) -> Result<Output> {
        git::run(&self.repo_path, arguments, environment, input, allowed)
    }
}

fn remove_if_present(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
        _ => Ok(()),
    }
}

/// `json.loads(bytes)` decodes by `json.detect_encoding`: a BOM or the NUL
/// pattern of the first bytes selects UTF-8, UTF-16 or UTF-32.
fn decode_json_bytes(content: &[u8]) -> Option<String> {
    fn utf16(units: &[u8], little: bool) -> Option<String> {
        if !units.len().is_multiple_of(2) {
            return None;
        }
        let words: Vec<u16> = units
            .chunks_exact(2)
            .map(|pair| {
                if little {
                    u16::from_le_bytes([pair[0], pair[1]])
                } else {
                    u16::from_be_bytes([pair[0], pair[1]])
                }
            })
            .collect();
        String::from_utf16(&words).ok()
    }
    fn utf32(units: &[u8], little: bool) -> Option<String> {
        if !units.len().is_multiple_of(4) {
            return None;
        }
        units
            .chunks_exact(4)
            .map(|quad| {
                let bytes = [quad[0], quad[1], quad[2], quad[3]];
                char::from_u32(if little {
                    u32::from_le_bytes(bytes)
                } else {
                    u32::from_be_bytes(bytes)
                })
            })
            .collect()
    }
    let b = content;
    if b.starts_with(&[0xff, 0xfe, 0, 0]) {
        return utf32(&b[4..], true);
    }
    if b.starts_with(&[0, 0, 0xfe, 0xff]) {
        return utf32(&b[4..], false);
    }
    if b.starts_with(&[0xff, 0xfe]) {
        return utf16(&b[2..], true);
    }
    if b.starts_with(&[0xfe, 0xff]) {
        return utf16(&b[2..], false);
    }
    if let Some(rest) = b.strip_prefix(&[0xef, 0xbb, 0xbf]) {
        return std::str::from_utf8(rest).ok().map(str::to_string);
    }
    if b.len() >= 4 {
        if b[0] == 0 {
            return if b[1] != 0 {
                utf16(b, false)
            } else {
                utf32(b, false)
            };
        }
        if b[1] == 0 {
            return if b[2] != 0 || b[3] != 0 {
                utf16(b, true)
            } else {
                utf32(b, true)
            };
        }
    } else if b.len() == 2 {
        if b[0] == 0 {
            return utf16(b, false);
        }
        if b[1] == 0 {
            return utf16(b, true);
        }
    }
    std::str::from_utf8(b).ok().map(str::to_string)
}

/// Python's `value not in {...}` for a TOML value against strings; a table
/// or array is unhashable and raises `TypeError`.
fn toml_in_set(value: Option<&toml::Value>, allowed: &[&str]) -> Result<bool> {
    match value {
        Some(toml::Value::Array(_)) => Err(notes::unhashable("list")),
        Some(toml::Value::Table(_)) => Err(notes::unhashable("dict")),
        Some(toml::Value::String(text)) => Ok(allowed.contains(&text.as_str())),
        _ => Ok(false),
    }
}

/// `_mutation_digest`: SHA-256 of the canonical JSON envelope, with every
/// byte field reduced to its own SHA-256 and length.
pub fn mutation_digest(mutation: &Mutation) -> String {
    let operations: Vec<Value> = mutation
        .operations
        .iter()
        .map(|operation| {
            let (name, fields) = operation.fields();
            let mut item = Dict::new();
            item.insert("type", name);
            for (field, value) in fields {
                match value {
                    Field::Text(text) => item.insert(field, text),
                    Field::Bytes(bytes) => {
                        let mut digest = Dict::new();
                        digest.insert("sha256", hex_digest(bytes));
                        digest.insert("bytes", bytes.len() as i64);
                        item.insert(field, digest);
                    }
                }
            }
            Value::Dict(item)
        })
        .collect();
    let mut envelope = Dict::new();
    envelope.insert("actor_type", mutation.actor_type.as_str());
    envelope.insert("device_id", mutation.device_id.as_str());
    envelope.insert("event_id", mutation.event_id.as_str());
    envelope.insert("operations", operations);
    envelope.insert("provider", mutation.provider.as_deref());
    hex_digest(json::dumps_compact_sorted(&Value::Dict(envelope)).as_bytes())
}

fn validate_mutation_envelope(mutation: &Mutation) -> Result<()> {
    validate_event_id(&mutation.event_id, "event ID")?;
    validate_event_id(&mutation.device_id, "device ID")?;
    validate_actor(&mutation.actor_type)?;
    if !matches!(
        mutation.provider.as_deref(),
        None | Some("codex" | "claude")
    ) {
        return Err(validation(format!(
            "unsupported provider metadata: {}",
            pystr::repr(mutation.provider.as_deref().unwrap_or_default())
        )));
    }
    if let Some(base) = &mutation.expected_base
        && !(matches!(base.len(), 40 | 64)
            && base
                .chars()
                .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)))
    {
        return Err(validation("expected_base must be a full Git object ID"));
    }
    if mutation.summary.contains('\n') || mutation.summary.contains('\r') {
        return Err(validation("commit summary must be one line"));
    }
    Ok(())
}

fn charset(value: &str, extra: &[char]) -> bool {
    value
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || extra.contains(&character))
}

fn validate_identity<'v>(value: &'v str, label: &str) -> Result<&'v str> {
    if (1..=128).contains(&value.len()) && charset(value, &['_', '.', '-']) {
        Ok(value)
    } else {
        Err(validation(format!(
            "invalid {label}: {}",
            pystr::repr(value)
        )))
    }
}

/// `_validate_ticket_id`.
pub fn validate_ticket_id(value: &str) -> Result<&str> {
    let valid = value.starts_with(|c: char| c.is_ascii_alphabetic())
        && value.len() <= 128
        && charset(value, &['_', '.', '-'])
        && value != "config"
        && value != "archive-index";
    if valid {
        Ok(value)
    } else {
        Err(validation(format!(
            "invalid ticket ID: {}",
            pystr::repr(value)
        )))
    }
}

fn validate_note_id(value: &str) -> Result<&str> {
    notes::validate_note_id(value)
        .map_err(|error| recast_contract(error, ErrorKind::Validation))?;
    Ok(value)
}

fn validate_artifact_id(value: &str) -> Result<&str> {
    if notes::is_artifact_id(value) {
        Ok(value)
    } else {
        Err(validation(format!(
            "invalid immutable artifact ID: {}",
            pystr::repr(value)
        )))
    }
}

/// `_validate_event_id`.
pub fn validate_event_id<'v>(value: &'v str, label: &str) -> Result<&'v str> {
    if (1..=160).contains(&value.len()) && charset(value, &['_', '.', ':', '-']) {
        Ok(value)
    } else {
        Err(validation(format!(
            "invalid {label}: {}",
            pystr::repr(value)
        )))
    }
}

fn validate_actor(value: &str) -> Result<&str> {
    if ["migration", "pm", "reviewer", "system", "user", "worker"].contains(&value) {
        Ok(value)
    } else {
        Err(validation(format!(
            "invalid provider-neutral actor type: {}",
            pystr::repr(value)
        )))
    }
}

fn validate_filename(value: &str) -> Result<&str> {
    if value.is_empty()
        || value == "."
        || value == ".."
        || value.len() > 255
        || value.contains('/')
        || value.contains('\\')
        || value.chars().any(|c| (c as u32) < 32)
    {
        return Err(validation(format!(
            "invalid attachment filename: {}",
            pystr::repr(value)
        )));
    }
    Ok(value)
}

fn is_ignored_materialization_name(name: &str) -> bool {
    IGNORED_MATERIALIZATION_NAMES.contains(&name) || name.starts_with("._")
}

fn expected_materialized_sha256(metadata: &Dict) -> BTreeMap<String, Value> {
    // Metadata from before the ignore list may include a Finder file;
    // dropping it keeps that upgrade from reading as a manual edit.
    let Some(Value::Dict(recorded)) = metadata.get("sha256") else {
        return BTreeMap::new();
    };
    recorded
        .iter()
        .filter(|(path, _)| {
            !parts(path)
                .iter()
                .any(|part| is_ignored_materialization_name(part))
        })
        .map(|(path, digest)| (path.to_string(), digest.clone()))
        .collect()
}

fn same_hashes(expected: &BTreeMap<String, Value>, actual: &BTreeMap<String, String>) -> bool {
    expected.len() == actual.len()
        && expected
            .iter()
            .all(|(path, digest)| actual.get(path).is_some_and(|found| digest.is_str(found)))
}

/// `_describe_materialization_difference`.
fn describe_materialization_difference(
    expected: &BTreeMap<String, Value>,
    actual: &BTreeMap<String, String>,
) -> String {
    let modified: Vec<&str> = expected
        .iter()
        .filter(|(path, digest)| actual.get(*path).is_some_and(|found| !digest.is_str(found)))
        .map(|(path, _)| path.as_str())
        .collect();
    let added: Vec<&str> = actual
        .keys()
        .filter(|path| !expected.contains_key(*path))
        .map(String::as_str)
        .collect();
    let removed: Vec<&str> = expected
        .keys()
        .filter(|path| !actual.contains_key(*path))
        .map(String::as_str)
        .collect();
    let mut groups = Vec::new();
    for (label, group) in [
        ("modified", modified),
        ("added", added),
        ("removed", removed),
    ] {
        if group.is_empty() {
            continue;
        }
        let shown = group[..group.len().min(MAX_DESCRIBED_MATERIALIZATION_PATHS)].join(", ");
        let extra = group
            .len()
            .saturating_sub(MAX_DESCRIBED_MATERIALIZATION_PATHS);
        groups.push(if extra > 0 {
            format!("{label}: {shown} and {extra} more")
        } else {
            format!("{label}: {shown}")
        });
    }
    groups.join("; ")
}

/// `_validate_allowlisted_path`: only the artifact layout may be committed.
pub fn validate_allowlisted_path(path: &str) -> Result<()> {
    let pieces = parts(path);
    if path.starts_with('/') || pieces.contains(&"..") {
        return Err(validation(format!(
            "artifact path traversal is prohibited: {}",
            pystr::repr(path)
        )));
    }
    if [
        ".orchestrator/config.toml",
        ".orchestrator/archive-index.jsonl",
        ".orchestrator/note-index.jsonl",
    ]
    .contains(&path)
    {
        return Ok(());
    }
    match pieces.as_slice() {
        [".orchestrator", name] if name.ends_with(".md") => {
            validate_ticket_id(&name[..name.len() - 3])?;
            Ok(())
        }
        [".orchestrator", "attachments", ticket, filename] => {
            validate_ticket_id(ticket)?;
            validate_filename(filename)?;
            Ok(())
        }
        [".orchestrator", "notes", name] if name.ends_with(".md") => {
            validate_note_id(&name[..name.len() - 3])?;
            Ok(())
        }
        [".orchestrator", "program", "events", name] if name.ends_with(".json") => {
            validate_event_id(&name[..name.len() - 5], "Program event ID")?;
            Ok(())
        }
        _ => Err(validation(format!(
            "artifact path is not allowlisted: {}",
            pystr::repr(path)
        ))),
    }
}

/// `_prepare_ticket_markdown`: the canonical ticket bytes, with the
/// immutable `artifact_id` inserted after `id` when it is missing.
pub fn prepare_ticket_markdown(
    ticket_id: &str,
    artifact_id: &str,
    content: &[u8],
) -> Result<Vec<u8>> {
    let text = std::str::from_utf8(content)
        .map_err(|_| validation(format!("ticket {ticket_id} is not UTF-8")))?;
    if text.contains('\0') {
        return Err(validation(format!("ticket {ticket_id} contains NUL bytes")));
    }
    if search(&FORBIDDEN_TEXT_MARKERS, content) {
        return Err(validation(format!(
            "ticket {ticket_id} contains an explicit raw transcript, trace, or hidden-reasoning marker"
        )));
    }
    let mut lines: Vec<String> = pystr::splitlines(text)
        .into_iter()
        .map(str::to_string)
        .collect();
    if lines.is_empty() || pystr::strip(&lines[0]) != "---" {
        return Err(validation(format!(
            "ticket {ticket_id} must have YAML front matter"
        )));
    }
    let closing = lines[1..]
        .iter()
        .position(|line| pystr::strip(line) == "---")
        .map(|index| index + 1)
        .ok_or_else(|| validation(format!("ticket {ticket_id} front matter is not closed")))?;
    let mut id_index = None;
    let mut artifact_index = None;
    for (index, line) in lines.iter().enumerate().take(closing).skip(1) {
        let (key, found, raw_value) = pystr::partition(line, ":");
        if !found {
            continue;
        }
        let value = pystr::strip_quotes(pystr::strip(raw_value));
        match pystr::strip(key) {
            "id" => {
                if value != ticket_id {
                    return Err(validation(format!(
                        "ticket front-matter ID {} does not match {}",
                        pystr::repr(value),
                        pystr::repr(ticket_id)
                    )));
                }
                id_index = Some(index);
            }
            "artifact_id" => {
                if value != artifact_id {
                    return Err(identity_error(format!(
                        "ticket immutable artifact_id {} does not match {}",
                        pystr::repr(value),
                        pystr::repr(artifact_id)
                    )));
                }
                artifact_index = Some(index);
            }
            _ => {}
        }
    }
    let Some(id_index) = id_index else {
        return Err(validation(format!(
            "ticket {ticket_id} has no front-matter id"
        )));
    };
    if artifact_index.is_none() {
        lines.insert(id_index + 1, format!("artifact_id: {artifact_id}"));
    }
    Ok(pystr::join_lines_with_final_newline(&lines).into_bytes())
}

fn recast_contract(error: Error, kind: ErrorKind) -> Error {
    if error.kind == ErrorKind::NoteContract {
        error.recast(kind)
    } else {
        error
    }
}

/// `_prepare_note_markdown`: the note re-rendered in canonical form.
fn prepare_note_markdown(
    note_id: &str,
    artifact_id: &str,
    project_id: &str,
    content: &[u8],
) -> Result<Vec<u8>> {
    let document = notes::parse_note_document(content).map_err(|error| {
        if error.kind == ErrorKind::NoteContract {
            validation(format!("note {note_id} is invalid: {error}"))
        } else {
            error
        }
    })?;
    if document.identity.note_id != note_id {
        return Err(validation(format!(
            "note front-matter ID {} does not match {}",
            pystr::repr(&document.identity.note_id),
            pystr::repr(note_id)
        )));
    }
    if document.identity.artifact_id != artifact_id {
        return Err(identity_error(format!(
            "note immutable artifact_id {} does not match {}",
            pystr::repr(&document.identity.artifact_id),
            pystr::repr(artifact_id)
        )));
    }
    if document.identity.project_id != project_id {
        return Err(identity_error(format!(
            "note project_id {} does not match {}",
            pystr::repr(&document.identity.project_id),
            pystr::repr(project_id)
        )));
    }
    notes::render_note_document(&document)
}

fn read_note_document(content: &[u8], note_id: &str) -> Result<notes::NoteDocument> {
    notes::parse_note_document(content).map_err(|error| {
        if error.kind == ErrorKind::NoteContract {
            validation(format!("note {note_id} is invalid: {error}"))
        } else {
            error
        }
    })
}

fn validate_note_index(content: &[u8], project_id: &str) -> Result<()> {
    let entries = notes::decode_note_index(content, project_id)
        .map_err(|error| recast_contract(error, ErrorKind::Validation))?;
    let mut catalog = Dict::new();
    for (artifact_id, entry) in entries {
        catalog.insert(&artifact_id, entry);
    }
    let forbidden = find_forbidden_keys(&Value::Dict(catalog));
    if !forbidden.is_empty() {
        return Err(validation(format!(
            "note index contains prohibited Git content: {}",
            forbidden.into_iter().collect::<Vec<_>>().join(", ")
        )));
    }
    Ok(())
}

/// `_ticket_front_matter_value`.
fn ticket_front_matter_value(content: &[u8], wanted: &str) -> Option<String> {
    let text = std::str::from_utf8(content).ok()?;
    let lines = pystr::splitlines(text);
    if lines.is_empty() || pystr::strip(lines[0]) != "---" {
        return None;
    }
    for line in &lines[1..] {
        if pystr::strip(line) == "---" {
            return None;
        }
        let (key, found, value) = pystr::partition(line, ":");
        if found && pystr::strip(key) == wanted {
            let value = pystr::strip_quotes(pystr::strip(value));
            return (!value.is_empty()).then(|| value.to_string());
        }
    }
    None
}

fn attachment_mime_for_filename(filename: &str) -> Result<&'static str> {
    match suffix_of(filename).as_str() {
        ".png" => Ok("image/png"),
        ".jpg" | ".jpeg" => Ok("image/jpeg"),
        ".gif" => Ok("image/gif"),
        ".webp" => Ok("image/webp"),
        ".pdf" => Ok("application/pdf"),
        _ => Err(validation(format!(
            "attachment extension is unsupported: {}",
            pystr::repr(filename)
        ))),
    }
}

/// `mimetypes.guess_type(filename)[0] or "unknown"`, for the refusal message
/// only. Python also reads the system's mime.types files, so a rare type may
/// be named differently here.
fn guessed_mime(filename: &str) -> &'static str {
    match suffix_of(filename).as_str() {
        ".png" => "image/png",
        ".jpg" | ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".pdf" => "application/pdf",
        ".heic" => "image/heic",
        ".svg" => "image/svg+xml",
        ".mp3" => "audio/mpeg",
        ".wav" => "audio/x-wav",
        ".m4a" => "audio/mp4a-latm",
        ".mp4" => "video/mp4",
        ".mov" => "video/quicktime",
        ".zip" => "application/zip",
        ".gz" | ".tgz" => "application/x-tar",
        ".tar" => "application/x-tar",
        ".txt" => "text/plain",
        ".md" => "text/markdown",
        ".json" => "application/json",
        ".html" | ".htm" => "text/html",
        ".exe" => "application/octet-stream",
        _ => "unknown",
    }
}

fn validate_attachment(filename: &str, mime_type: &str, content: &[u8]) -> Result<()> {
    if content.len() > ATTACHMENT_MAX_BYTES {
        return Err(validation(format!(
            "attachment {} is {} bytes; limit is {ATTACHMENT_MAX_BYTES}",
            pystr::repr(filename),
            content.len()
        )));
    }
    type Policy = (&'static [&'static str], fn(&[u8]) -> bool);
    let policy: Option<Policy> = match mime_type.to_lowercase().as_str() {
        "image/png" => Some((&[".png"], |data| data.starts_with(b"\x89PNG\r\n\x1a\n"))),
        "image/jpeg" => Some((&[".jpg", ".jpeg"], |data| data.starts_with(b"\xff\xd8\xff"))),
        "image/gif" => Some((&[".gif"], |data| {
            data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a")
        })),
        "image/webp" => Some((&[".webp"], |data| {
            data.len() >= 12 && &data[..4] == b"RIFF" && &data[8..12] == b"WEBP"
        })),
        "application/pdf" => Some((&[".pdf"], |data| data.starts_with(b"%PDF-"))),
        _ => None,
    };
    let Some((extensions, signature_matches)) = policy else {
        return Err(validation(format!(
            "attachment MIME {} is unsupported (filename suggests {}); \
             raw audio, archives, executables, and large binaries stay outside Git",
            pystr::repr(mime_type),
            guessed_mime(filename)
        )));
    };
    if !extensions.contains(&suffix_of(filename).as_str()) {
        return Err(validation(format!(
            "attachment filename {} does not match MIME {}",
            pystr::repr(filename),
            pystr::repr(mime_type)
        )));
    }
    if !signature_matches(content) {
        return Err(validation(format!(
            "attachment {} bytes do not match declared MIME {}",
            pystr::repr(filename),
            pystr::repr(mime_type)
        )));
    }
    Ok(())
}

fn validate_archive_index(content: &[u8]) -> Result<()> {
    let text =
        std::str::from_utf8(content).map_err(|_| validation("archive index is not UTF-8"))?;
    for (index, line) in pystr::splitlines(text).into_iter().enumerate() {
        let line_number = index + 1;
        if pystr::strip(line).is_empty() {
            continue;
        }
        let value = json::parse(line).ok_or_else(|| {
            validation(format!(
                "archive index line {line_number} is invalid JSON: Expecting value"
            ))
        })?;
        if value.as_dict().is_none() {
            return Err(validation(format!(
                "archive index line {line_number} is not an object"
            )));
        }
        let forbidden = find_forbidden_keys(&value);
        if !forbidden.is_empty() {
            return Err(validation(format!(
                "archive index line {line_number} contains prohibited Git content: {}",
                forbidden.into_iter().collect::<Vec<_>>().join(", ")
            )));
        }
    }
    Ok(())
}

fn reject_secrets(content: &[u8], label: &str) -> Result<()> {
    if search(&SECRET_PATTERNS, content) {
        return Err(validation(format!(
            "{label} appears to contain a credential or private key; Git commit refused"
        )));
    }
    Ok(())
}

fn reject_note_private_runtime(content: &[u8], note_id: &str) -> Result<()> {
    if search(&FORBIDDEN_NOTE_MARKERS, content) {
        return Err(validation(format!(
            "note {note_id} contains private provider trace, hidden reasoning, tool output, or raw audio"
        )));
    }
    Ok(())
}

/// `_find_forbidden_keys`: prohibited keys anywhere in a JSON value.
fn find_forbidden_keys(value: &Value) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    match value {
        Value::Dict(dict) => {
            for (key, child) in dict.iter() {
                let normalized = pystr::strip(key).to_lowercase();
                if FORBIDDEN_JSON_KEYS.contains(&normalized.as_str()) {
                    found.insert(normalized);
                }
                found.extend(find_forbidden_keys(child));
            }
        }
        Value::List(items) => {
            for child in items {
                found.extend(find_forbidden_keys(child));
            }
        }
        _ => {}
    }
    found
}

/// `_parse_trailers`: `Key: value` lines, a later key replacing an earlier.
fn parse_trailers(message: &str) -> HashMap<String, String> {
    let mut trailers = HashMap::new();
    for line in pystr::splitlines(message) {
        let key_end = line
            .char_indices()
            .find(|(index, character)| {
                !(character.is_ascii_alphabetic()
                    || (*index > 0 && (character.is_ascii_digit() || *character == '-')))
            })
            .map_or(line.len(), |(index, _)| index);
        if key_end == 0 || !line[key_end..].starts_with(':') {
            continue;
        }
        let value = line[key_end + 1..].trim_start_matches(pystr::is_space);
        trailers.insert(line[..key_end].to_string(), value.to_string());
    }
    trailers
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ticket_markdown_gains_its_artifact_id() {
        let prepared = prepare_ticket_markdown(
            "RR-1",
            "ticket-11111111",
            "---\r\nid: \"RR-1\"\r\ntitle: T\r\n---\r\nBody\u{2028}line\n\n\n".as_bytes(),
        )
        .unwrap();
        assert_eq!(
            prepared,
            b"---\nid: \"RR-1\"\nartifact_id: ticket-11111111\ntitle: T\n---\nBody\nline\n"
        );
        let mismatch = prepare_ticket_markdown(
            "RR-1",
            "ticket-11111111",
            b"---\nid: RR-1\nartifact_id: ticket-2\n---\n",
        );
        assert_eq!(mismatch.unwrap_err().kind, ErrorKind::Identity);
        let marker = prepare_ticket_markdown(
            "RR-1",
            "ticket-11111111",
            b"---\nid: RR-1\n---\n  RAW_Transcript :\n",
        );
        assert_eq!(marker.unwrap_err().kind, ErrorKind::Validation);
    }

    #[test]
    fn secrets_match_as_python_bytes_patterns_do() {
        let secret = |text: &str| reject_secrets(text.as_bytes(), "x").is_err();
        assert!(secret("key AKIAABCDEFGHIJKLMNOP end"));
        assert!(secret("éAKIAABCDEFGHIJKLMNOP"));
        assert!(!secret("xAKIAABCDEFGHIJKLMNOP"));
        assert!(secret("sk-abcdefghij0123456789"));
        assert!(!secret("sk-abcdefghij012345678-"));
        assert!(secret("sk-abcdefghij012345678-x"));
        assert!(secret("API-KEY = 'abcdefghijklmnopqrstuvwxyz'"));
        assert!(!secret("api_\u{212a}ey = abcdefghijklmnopqrstuvwxyz"));
        assert!(secret("-----BEGIN OPENSSH PRIVATE KEY-----"));
    }

    #[test]
    fn digests_cover_every_field() {
        let mut mutation = Mutation::new(
            "event-1",
            "user",
            "device-1",
            vec![Operation::ConfigWrite {
                content: b"x".to_vec(),
            }],
        );
        let first = mutation_digest(&mutation);
        mutation.provider = Some("claude".to_string());
        assert_ne!(first, mutation_digest(&mutation));
        assert_eq!(first.len(), 64);
    }

    #[test]
    fn allowlist_and_path_parts() {
        for allowed in [
            ".orchestrator/config.toml",
            ".orchestrator/RR-1.md",
            ".orchestrator/attachments/RR-1/a.png",
            ".orchestrator/notes/RR-N1.md",
            ".orchestrator/program/events/e:1.json",
        ] {
            assert!(validate_allowlisted_path(allowed).is_ok(), "{allowed}");
        }
        for refused in [
            "/etc/passwd",
            ".orchestrator/../x.md",
            ".orchestrator/config.md",
            ".orchestrator/x/y.md",
            "README.md",
        ] {
            assert!(validate_allowlisted_path(refused).is_err(), "{refused}");
        }
        assert_eq!(stem_of(".orchestrator/program/events/a.b.json"), "a.b");
        assert_eq!(suffix_of("a.PNG"), ".png");
        assert_eq!(suffix_of(".png"), "");
        assert_eq!(suffix_of("a."), ".");
    }

    #[test]
    fn trailers_and_json_encodings() {
        let trailers =
            parse_trailers("Summary: x\n\nRelay-Event-ID:  e-1\nNot a: trailer\n1x: no\n");
        assert_eq!(trailers["Relay-Event-ID"], "e-1");
        assert_eq!(trailers["Summary"], "x");
        assert!(!trailers.contains_key("1x"));
        let utf16: Vec<u8> = "{\"a\":1}"
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect();
        assert_eq!(decode_json_bytes(&utf16).as_deref(), Some("{\"a\":1}"));
        assert_eq!(decode_json_bytes(b"\xef\xbb\xbf{}").as_deref(), Some("{}"));
    }
}
