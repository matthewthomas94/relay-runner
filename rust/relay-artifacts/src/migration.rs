//! `services/artifact_migration.py` (and `artifact_migration_cli.py`): the
//! journaled legacy-board migration onto `refs/heads/relay/artifacts`.
//!
//! The legacy `.orchestrator/` tree is inspected without writes, captured in
//! a private journal and backup, bootstrapped through the store's typed
//! writer, removed from the source branch with a private Git index and then
//! rematerialized from the artifact ref. Every state-changing step is
//! idempotent and the journal is the rollback authority.
//!
//! Everything this leaves behind is the Python module's own form, so a
//! migration started by one daemon can be resumed or rolled back by the
//! other: the journal, preflight, registry backup and legacy-tree backup
//! under `<state>/artifacts/<project>/legacy-migration/`, the registry-v2
//! rewrite, the bootstrap commit and the source commit that stops tracking
//! `.orchestrator/`.
//!
//! The Program capture export and the Graphify rebuild (`program_artifacts`
//! and `graphify_*`, ported in RR-499) run through the temporary bridge
//! `services/artifact_migration_program_bridge.py`, which runs Python's own
//! `_migrate_program_and_rebuild` under the writer lock this process holds.
//! The bridge is only needed when a Graphify database path is configured.
//!
//! Known differences, each refused or reported the same way as in Python:
//!
//! - JSON decode failures omit Python's position details, as everywhere in
//!   this crate, and a SQLite failure reports SQLite's own message.
//! - A legacy `next_id` beyond `i64` is refused as malformed, where Python's
//!   unbounded `int` would take it.
//! - The legacy tree is walked in sorted name order, where `os.walk` follows
//!   the directory's order; only which of several blockers is named first
//!   can differ.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256::hex_digest;

use crate::instant::Instant;
use crate::retention::{ArtifactRetentionManager, RetentionOptions, configured_remote_urls};
use crate::rollout::dumps_indent_sorted;
use crate::store::{self, ARTIFACT_REF, ArtifactStore, Mutation, Operation, StoreOptions};
use crate::{Error, ErrorKind, Result, paths, pystr, tickets, toml};

pub const MIGRATION_SCHEMA_VERSION: i64 = 1;
pub const ACTIVE_RUN_STATES: [&str; 8] = [
    "Claimed",
    "Running",
    "SpikeResultReady",
    "AwaitingReview",
    "Reviewing",
    "MergeConflict",
    "IntegrationBlocked",
    "Succeeded",
];
const LEGACY_CONFIG_KEYS: [&str; 2] = ["prefix", "next_id"];
const RESUMABLE_STAGES: [&str; 4] = [
    "materialized",
    "program_rebuilt",
    "retention_previewed",
    "complete",
];

/// A test hook called at named stages; an error interrupts the migration.
pub type MigrationInjector = Box<dyn Fn(&str) -> Result<()> + Send + Sync>;

// -- errors ---------------------------------------------------------------------

fn migration_error(
    kind: ErrorKind,
    message: impl Into<String>,
    recovery: &str,
    report: Dict,
) -> Error {
    Error::new(kind, message)
        .with_recovery(recovery)
        .with_report(Value::Dict(report))
}

fn blocked(message: impl Into<String>, recovery: &str) -> Error {
    migration_error(ErrorKind::MigrationBlocked, message, recovery, Dict::new())
}

fn blocked_with(message: impl Into<String>, recovery: &str, report: &Dict) -> Error {
    migration_error(
        ErrorKind::MigrationBlocked,
        message,
        recovery,
        report.clone(),
    )
}

fn reconciliation(message: impl Into<String>, recovery: &str, report: &Dict) -> Error {
    migration_error(
        ErrorKind::MigrationReconciliationRequired,
        message,
        recovery,
        report.clone(),
    )
}

/// `repr(value)` for a JSON value, `None` when absent.
fn value_repr(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => "None".to_string(),
        Some(Value::Str(text)) => pystr::repr(text),
        Some(other) => other.py_str(),
    }
}

/// `str(OSError)`: `[Errno N] <message>: '<path>'`.
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

fn io_error(error: std::io::Error, path: &Path) -> Error {
    Error::new(ErrorKind::Io, os_error(&error, path))
}

// -- small Python equivalents ---------------------------------------------------------

fn sha256(content: &[u8]) -> String {
    hex_digest(content)
}

/// `_json_digest`: SHA-256 of the sorted compact `ensure_ascii=False` JSON.
fn json_digest(value: &Value) -> String {
    sha256(json::dumps_compact_sorted_unicode(value).as_bytes())
}

/// `_file_manifest_digest`.
fn file_manifest_digest(files: &Dict) -> String {
    let mut evidence = Dict::new();
    let mut paths: Vec<(&str, &Value)> = files.iter().collect();
    paths.sort_by(|left, right| left.0.cmp(right.0));
    for (path, meta) in paths {
        let meta = meta.as_dict().cloned().unwrap_or_default();
        let mut entry = Dict::new();
        entry.insert("sha256", meta.get("sha256").cloned().unwrap_or(Value::Null));
        entry.insert("bytes", meta.get("bytes").cloned().unwrap_or(Value::Null));
        entry.insert(
            "mtime_ns",
            meta.get("mtime_ns").cloned().unwrap_or(Value::Null),
        );
        entry.insert("tracked", meta.get("tracked").is_some_and(Value::truthy));
        evidence.insert(path, entry);
    }
    json_digest(&Value::Dict(evidence))
}

fn now_iso() -> String {
    Instant::now().isoformat_micros_z()
}

/// `_mtime_iso`: `datetime.fromtimestamp(mtime_ns / 1e9, UTC)` with
/// round-half-even microseconds.
fn mtime_iso(mtime_ns: i64) -> String {
    let seconds = mtime_ns as f64 / 1e9;
    let mut whole = seconds.trunc();
    let mut micros = (seconds.fract() * 1e6).round_ties_even();
    if micros >= 1e6 {
        micros -= 1e6;
        whole += 1.0;
    } else if micros < 0.0 {
        micros += 1e6;
        whole -= 1.0;
    }
    Instant::from_unix_micros(whole as i64 * 1_000_000 + micros as i64).isoformat_micros_z()
}

/// `str.splitlines(keepends=True)`.
fn splitlines_keepends(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut characters = text.char_indices().peekable();
    while let Some((index, character)) = characters.next() {
        let breaks = matches!(
            character,
            '\n' | '\r'
                | '\u{b}'
                | '\u{c}'
                | '\u{1c}'
                | '\u{1d}'
                | '\u{1e}'
                | '\u{85}'
                | '\u{2028}'
                | '\u{2029}'
        );
        if !breaks {
            continue;
        }
        let mut end = index + character.len_utf8();
        if character == '\r' && characters.peek().map(|(_, next)| *next) == Some('\n') {
            characters.next();
            end += 1;
        }
        lines.push(&text[start..end]);
        start = end;
    }
    if start < text.len() {
        lines.push(&text[start..]);
    }
    lines
}

/// `PurePosixPath(path).parts` for the relative paths the migration sees.
fn parts(path: &str) -> Vec<&str> {
    path.split('/')
        .filter(|part| !part.is_empty() && *part != ".")
        .collect()
}

/// `PurePosixPath(path).name`.
fn name_of(path: &str) -> &str {
    parts(path).last().copied().unwrap_or("")
}

/// `PurePosixPath(path).suffix`, as `store` reads it.
fn suffix_of(path: &str) -> &str {
    let name = name_of(path);
    let trimmed = name.trim_start_matches('.');
    match trimmed.rfind('.') {
        Some(index) => &trimmed[index..],
        None => "",
    }
}

/// `PurePosixPath(path).stem`.
fn stem_of(path: &str) -> &str {
    let name = name_of(path);
    let suffix = suffix_of(path);
    &name[..name.len() - suffix.len()]
}

fn is_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink())
}

fn is_file(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|metadata| metadata.is_file())
}

fn is_dir(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|metadata| metadata.is_dir())
}

/// `Path(text).expanduser().resolve()`.
fn resolve_user(text: &str) -> Result<PathBuf> {
    Ok(PathBuf::from(paths::resolve(&paths::expanduser(text)?)))
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// `os.walk(root, followlinks=False)` top-down, names sorted: each
/// directory with its subdirectory and file names.
/// Each directory with its subdirectory and file names.
type Walk = Vec<(PathBuf, Vec<String>, Vec<String>)>;

fn walk(root: &Path) -> Result<Walk> {
    let mut result = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let mut names: Vec<String> = match fs::read_dir(&directory) {
            Ok(entries) => entries
                .filter_map(|entry| entry.ok())
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect(),
            Err(_) => continue,
        };
        names.sort();
        let (directories, files): (Vec<String>, Vec<String>) = names
            .into_iter()
            .partition(|name| is_dir(&directory.join(name)));
        for name in directories.iter().rev() {
            let child = directory.join(name);
            if !is_symlink(&child) {
                pending.push(child);
            }
        }
        result.push((directory, directories, files));
    }
    Ok(result)
}

/// `sorted(root.rglob("*"))` regular, non-symlink files, relative POSIX.
fn regular_files(root: &Path) -> Vec<(String, PathBuf)> {
    let mut result = Vec::new();
    let mut pending = vec![(root.to_path_buf(), String::new())];
    while let Some((directory, prefix)) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.filter_map(|entry| entry.ok()) {
            let name = entry.file_name().to_string_lossy().into_owned();
            let path = entry.path();
            let relative = if prefix.is_empty() {
                name
            } else {
                format!("{prefix}/{name}")
            };
            if is_symlink(&path) {
                continue;
            }
            if is_dir(&path) {
                pending.push((path, relative));
            } else if is_file(&path) {
                result.push((relative, path));
            }
        }
    }
    result.sort();
    result
}

fn random_hex() -> String {
    store::random_hex()
}

/// `path.with_name(path.name + suffix)`.
fn beside(path: &Path, suffix: &str) -> PathBuf {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    path.with_file_name(format!("{name}{suffix}"))
}

fn chmod(path: &Path, mode: u32) -> Result<()> {
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .map_err(|error| io_error(error, path))
}

/// `_write_json`: sorted, indented, `0600`, atomically replaced.
fn write_json(path: &Path, value: &Dict) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| io_error(error, parent))?;
    }
    let temporary = beside(path, &format!(".{}.tmp", random_hex()));
    let text = dumps_indent_sorted(&Value::Dict(value.clone())) + "\n";
    fs::write(&temporary, text).map_err(|error| io_error(error, &temporary))?;
    chmod(&temporary, 0o600)?;
    fs::rename(&temporary, path).map_err(|error| io_error(error, path))
}

/// `json.loads(path.read_text())` as an object, or `{}` for any failure.
fn read_json_object(path: &Path) -> Dict {
    let Ok(bytes) = fs::read(path) else {
        return Dict::new();
    };
    let Ok(text) = std::str::from_utf8(&bytes) else {
        return Dict::new();
    };
    match json::parse(&pystr::universal_newlines(text)) {
        Some(Value::Dict(dict)) => dict,
        _ => Dict::new(),
    }
}

fn get_str(dict: &Dict, key: &str) -> String {
    dict.get(key).map(Value::py_str).unwrap_or_default()
}

/// `str(d.get(key) or "")`.
fn get_text(dict: &Dict, key: &str) -> String {
    dict.string(key)
}

fn get_dict(dict: &Dict, key: &str) -> Dict {
    dict.get(key)
        .and_then(Value::as_dict)
        .cloned()
        .unwrap_or_default()
}

fn get_bool(dict: &Dict, key: &str) -> bool {
    dict.get(key).is_some_and(Value::truthy)
}

fn strings(values: &[String]) -> Value {
    Value::List(
        values
            .iter()
            .map(|value| Value::Str(value.clone()))
            .collect(),
    )
}

/// `_artifact_id`.
fn artifact_id_for(project_id: &str, ticket_id: &str) -> String {
    format!(
        "ticket-{}",
        &sha256(format!("{project_id}:{ticket_id}").as_bytes())[..40]
    )
}

/// `_front_value`.
fn front_value(content: &[u8], key: &str) -> Option<String> {
    let text = std::str::from_utf8(content).ok()?;
    let lines = pystr::splitlines(text);
    if lines
        .first()
        .is_none_or(|line| json::py_strip(line) != "---")
    {
        return None;
    }
    for line in &lines[1..] {
        if json::py_strip(line) == "---" {
            break;
        }
        let (field, found, value) = pystr::partition(line, ":");
        if found && json::py_strip(field) == key {
            let value = json::py_strip(value)
                .trim_matches(|character| character == '"' || character == '\'');
            return (!value.is_empty()).then(|| value.to_string());
        }
    }
    None
}

fn decode(content: &[u8]) -> Result<&str> {
    pystr::decode_utf8(content)
}

/// `legacy_ticket_content`: older writers omitted the false cancellation
/// flag; their body is preserved.
pub fn legacy_ticket_content(content: &[u8]) -> Result<Vec<u8>> {
    let text = decode(content)?;
    let mut lines: Vec<String> = splitlines_keepends(text)
        .into_iter()
        .map(str::to_string)
        .collect();
    if lines
        .first()
        .is_some_and(|line| json::py_strip(line) == "---")
        && front_value(content, "canceled").is_none()
        && let Some(closing) = lines
            .iter()
            .enumerate()
            .skip(1)
            .find(|(_, line)| json::py_strip(line) == "---")
            .map(|(index, _)| index)
    {
        lines.insert(closing, "canceled: false\n".to_string());
    }
    Ok(lines.concat().into_bytes())
}

/// `_set_frontmatter_defaults`.
fn set_frontmatter_defaults(
    content: &[u8],
    artifact_id: &str,
    activity_at: &str,
) -> Result<Vec<u8>> {
    let legacy = legacy_ticket_content(content)?;
    let text = decode(&legacy)?;
    let mut lines: Vec<String> = pystr::splitlines(text)
        .into_iter()
        .map(str::to_string)
        .collect();
    let missing = || Error::new(ErrorKind::Runtime, "generator raised StopIteration");
    let mut closing = lines
        .iter()
        .enumerate()
        .skip(1)
        .find(|(_, line)| json::py_strip(line) == "---")
        .map(|(index, _)| index)
        .ok_or_else(missing)?;
    let id_index = (1..closing)
        .find(|index| json::py_strip(pystr::partition(&lines[*index], ":").0) == "id")
        .ok_or_else(missing)?;
    let mut insert_at = id_index + 1;
    if front_value(content, "artifact_id").is_none() {
        lines.insert(insert_at, format!("artifact_id: {artifact_id}"));
        closing += 1;
        insert_at += 1;
    }
    let _ = closing;
    if front_value(content, "activity_at").is_none() {
        lines.insert(insert_at, format!("activity_at: {activity_at}"));
    }
    Ok((lines.join("\n").trim_end_matches('\n').to_string() + "\n").into_bytes())
}

/// `_safe_remote_locator`: a remote URL without credentials, query or
/// fragment.
fn safe_remote_locator(url: &str) -> Result<String> {
    if !url.contains("://") {
        if url.contains('@') && url.contains(':') {
            return Ok(format!(
                "ssh://{}",
                url.split_once('@').map_or("", |(_, rest)| rest)
            ));
        }
        return Ok(format!(
            "local-path:{}",
            paths::normalize(&paths::expanduser(url)?)
        ));
    }
    // urllib.parse.urlsplit
    let mut scheme = String::new();
    let mut rest = url;
    if let Some(index) = url.find(':') {
        let candidate = &url[..index];
        if candidate
            .chars()
            .next()
            .is_some_and(|first| first.is_ascii_alphabetic())
            && candidate
                .chars()
                .all(|character| character.is_ascii_alphanumeric() || "+-.".contains(character))
        {
            scheme = candidate.to_ascii_lowercase();
            rest = &url[index + 1..];
        }
    }
    let mut netloc = "";
    if let Some(after) = rest.strip_prefix("//") {
        let end = after.find(['/', '?', '#']).unwrap_or(after.len());
        netloc = &after[..end];
        rest = &after[end..];
    }
    let rest = rest.split('#').next().unwrap_or("");
    let path = rest.split('?').next().unwrap_or("");
    let hostinfo = netloc.rsplit_once('@').map_or(netloc, |(_, host)| host);
    let (host, port) = if let Some(bracketed) = hostinfo.strip_prefix('[') {
        let (inside, after) = bracketed.split_once(']').unwrap_or((bracketed, ""));
        (inside.to_string(), after.strip_prefix(':').unwrap_or(""))
    } else {
        let (host, _, port) = pystr::partition(hostinfo, ":");
        (host.to_string(), port)
    };
    let host = host.to_lowercase();
    let port = if port.is_empty() {
        String::new()
    } else {
        match port.parse::<u32>() {
            Ok(number)
                if port.chars().all(|character| character.is_ascii_digit()) && number <= 65535 =>
            {
                if number == 0 {
                    String::new()
                } else {
                    format!(":{number}")
                }
            }
            Ok(_) => return Err(Error::value("Port out of range 0-65535")),
            Err(_) => {
                return Err(Error::value(format!(
                    "Port could not be cast to integer value as {}",
                    pystr::repr(port)
                )));
            }
        }
    };
    let netloc = host + &port;
    let mut rendered = path.to_string();
    if !netloc.is_empty() {
        if !rendered.is_empty() && !rendered.starts_with('/') {
            rendered = format!("/{rendered}");
        }
        rendered = format!("//{netloc}{rendered}");
    } else if rendered.starts_with("//")
        || (USES_NETLOC.contains(&scheme.as_str())
            && (rendered.is_empty() || rendered.starts_with('/')))
    {
        rendered = format!("//{rendered}");
    }
    if !scheme.is_empty() {
        rendered = format!("{scheme}:{rendered}");
    }
    Ok(rendered)
}

const USES_NETLOC: [&str; 27] = [
    "",
    "ftp",
    "http",
    "gopher",
    "nntp",
    "telnet",
    "imap",
    "wais",
    "file",
    "mms",
    "https",
    "shttp",
    "snews",
    "prospero",
    "rtsp",
    "rtsps",
    "rtspu",
    "rsync",
    "svn",
    "svn+ssh",
    "sftp",
    "nfs",
    "git",
    "git+ssh",
    "ws",
    "wss",
    "itms-services",
];

/// `_bounded_public_error`: Git's message on one line, credentials in
/// HTTP URLs removed, at most 500 characters.
fn bounded_public_error(stderr: &[u8]) -> String {
    let text = String::from_utf8_lossy(stderr);
    let text = pystr::strip(&text).replace('\n', " ");
    let mut cleaned = String::with_capacity(text.len());
    let mut rest = text.as_str();
    'scan: while !rest.is_empty() {
        let lower = rest.to_ascii_lowercase();
        for scheme in ["https://", "http://"] {
            if lower.starts_with(scheme) {
                let after = &rest[scheme.len()..];
                let span = after
                    .find(|character: char| {
                        character == '/' || character == '@' || character.is_whitespace()
                    })
                    .unwrap_or(after.len());
                cleaned.push_str(&rest[..scheme.len()]);
                if span > 0 && after[span..].starts_with('@') {
                    rest = &after[span + 1..];
                } else {
                    rest = after;
                }
                continue 'scan;
            }
        }
        let character = rest.chars().next().unwrap_or_default();
        cleaned.push(character);
        rest = &rest[character.len_utf8()..];
    }
    let bounded: String = cleaned.chars().take(500).collect();
    if bounded.is_empty() {
        "unknown Git error".to_string()
    } else {
        bounded
    }
}

fn is_remote_name(name: &str) -> bool {
    (1..=128).contains(&name.len())
        && name
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "_.-".contains(character))
}

fn is_hex_oid(value: &str) -> bool {
    (value.len() == 40 || value.len() == 64)
        && value
            .chars()
            .all(|character| character.is_ascii_digit() || ('a'..='f').contains(&character))
}

// -- processes ------------------------------------------------------------------------

struct ProcessOutput {
    status: i32,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

/// Runs `command`, feeding `input`; `Ok(None)` when it outlives `timeout`.
fn run_process(
    mut command: Command,
    input: Option<&[u8]>,
    timeout: Option<f64>,
) -> std::io::Result<Option<ProcessOutput>> {
    command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn()?;
    let mut stdout = child.stdout.take();
    let mut stderr = child.stderr.take();
    let stdin = child.stdin.take();
    let deadline =
        timeout.map(|seconds| std::time::Instant::now() + Duration::from_secs_f64(seconds));
    std::thread::scope(|scope| {
        if let (Some(bytes), Some(mut stdin)) = (input, stdin) {
            scope.spawn(move || {
                let _ = stdin.write_all(bytes);
            });
        }
        let out = scope.spawn(move || {
            let mut buffer = Vec::new();
            if let Some(stream) = stdout.as_mut() {
                let _ = stream.read_to_end(&mut buffer);
            }
            buffer
        });
        let err = scope.spawn(move || {
            let mut buffer = Vec::new();
            if let Some(stream) = stderr.as_mut() {
                let _ = stream.read_to_end(&mut buffer);
            }
            buffer
        });
        let status = loop {
            if let Some(status) = child.try_wait()? {
                break Some(status);
            }
            if deadline.is_some_and(|deadline| std::time::Instant::now() >= deadline) {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            std::thread::sleep(Duration::from_millis(5));
        };
        let stdout = out.join().unwrap_or_default();
        let stderr = err.join().unwrap_or_default();
        Ok(status.map(|status| ProcessOutput {
            status: status
                .code()
                .unwrap_or_else(|| -status.signal().unwrap_or(0)),
            stdout,
            stderr,
        }))
    })
}

fn text_of(bytes: &[u8]) -> String {
    pystr::strip(&String::from_utf8_lossy(bytes)).to_string()
}

// -- results --------------------------------------------------------------------

/// `MigrationPreview`.
#[derive(Clone, Debug, Default)]
pub struct MigrationPreview {
    pub project_id: String,
    pub repo_path: String,
    pub common_directory: String,
    pub source_branch: String,
    pub default_branch: String,
    pub source_head: String,
    pub manifest: Dict,
    pub manifest_digest: String,
    pub registry_record: Dict,
    pub git: Dict,
    pub run_references: Vec<Dict>,
    pub program_references: Vec<Dict>,
    pub remote: Dict,
    pub blockers: Vec<Dict>,
}

impl MigrationPreview {
    pub fn can_migrate(&self) -> bool {
        self.blockers.is_empty()
    }

    /// `dataclasses.asdict(preview)`.
    pub fn as_dict(&self) -> Dict {
        let dicts = |items: &[Dict]| Value::List(items.iter().cloned().map(Value::Dict).collect());
        let mut result = Dict::new();
        result.insert("project_id", self.project_id.as_str());
        result.insert("repo_path", self.repo_path.as_str());
        result.insert("common_directory", self.common_directory.as_str());
        result.insert("source_branch", self.source_branch.as_str());
        result.insert("default_branch", self.default_branch.as_str());
        result.insert("source_head", self.source_head.as_str());
        result.insert("manifest", self.manifest.clone());
        result.insert("manifest_digest", self.manifest_digest.as_str());
        result.insert("registry_record", self.registry_record.clone());
        result.insert("git", self.git.clone());
        result.insert("run_references", dicts(&self.run_references));
        result.insert("program_references", dicts(&self.program_references));
        result.insert("remote", self.remote.clone());
        result.insert("blockers", dicts(&self.blockers));
        result
    }
}

/// `MigrationResult`.
#[derive(Clone, Debug)]
pub struct MigrationResult {
    pub project_id: String,
    pub stage: String,
    pub artifact_commit: String,
    pub source_commit: Option<String>,
    pub manifest_digest: String,
    pub remote_result: Dict,
    pub retention_preview: Dict,
    pub journal_path: String,
    pub idempotent: bool,
}

impl MigrationResult {
    pub fn as_dict(&self) -> Dict {
        let mut result = Dict::new();
        result.insert("project_id", self.project_id.as_str());
        result.insert("stage", self.stage.as_str());
        result.insert("artifact_commit", self.artifact_commit.as_str());
        result.insert("source_commit", self.source_commit.clone());
        result.insert("manifest_digest", self.manifest_digest.as_str());
        result.insert("remote_result", self.remote_result.clone());
        result.insert("retention_preview", self.retention_preview.clone());
        result.insert("journal_path", self.journal_path.as_str());
        result.insert("idempotent", self.idempotent);
        result
    }
}

/// `RollbackResult`.
#[derive(Clone, Debug)]
pub struct RollbackResult {
    pub project_id: String,
    pub stage: String,
    pub artifact_ref_retained: bool,
    pub source_commit: Option<String>,
    pub journal_path: String,
    pub idempotent: bool,
}

impl RollbackResult {
    pub fn as_dict(&self) -> Dict {
        let mut result = Dict::new();
        result.insert("project_id", self.project_id.as_str());
        result.insert("stage", self.stage.as_str());
        result.insert("artifact_ref_retained", self.artifact_ref_retained);
        result.insert("source_commit", self.source_commit.clone());
        result.insert("journal_path", self.journal_path.as_str());
        result.insert("idempotent", self.idempotent);
        result
    }
}

// -- the coordinator -----------------------------------------------------------------

/// `ArtifactMigrationCoordinator`'s keyword arguments.
pub struct MigrationOptions {
    pub runs_db_path: Option<PathBuf>,
    pub graphify_path: Option<PathBuf>,
    pub device_id: String,
    pub provider: Option<String>,
    pub failure_injector: Option<MigrationInjector>,
    pub remote_timeout_seconds: f64,
    pub remote_name: Option<String>,
    /// The command that runs the Program/Graphify step; the default is
    /// `RELAY_ARTIFACT_PROGRAM_BRIDGE`, or `python3` (`RELAY_PYTHON`) with
    /// `services/artifact_migration_program_bridge.py`.
    pub program_bridge: Option<Vec<String>>,
}

impl Default for MigrationOptions {
    fn default() -> Self {
        Self {
            runs_db_path: None,
            graphify_path: None,
            device_id: "migration-device".to_string(),
            provider: None,
            failure_injector: None,
            remote_timeout_seconds: 15.0,
            remote_name: None,
            program_bridge: None,
        }
    }
}

/// The bridge command when none is configured.
fn default_program_bridge() -> Vec<String> {
    if let Ok(configured) = std::env::var("RELAY_ARTIFACT_PROGRAM_BRIDGE")
        && !configured.trim().is_empty()
    {
        return configured.split_whitespace().map(str::to_string).collect();
    }
    let python = std::env::var("RELAY_PYTHON")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "python3".to_string());
    let services = std::env::var("RELAY_SERVICES_DIR")
        .ok()
        .filter(|value| !value.is_empty())
        .map_or_else(
            || Path::new(env!("CARGO_MANIFEST_DIR")).join("../../services"),
            PathBuf::from,
        );
    vec![
        python,
        path_text(&services.join("artifact_migration_program_bridge.py")),
    ]
}

/// `ArtifactMigrationCoordinator`: one project's journaled migration.
pub struct ArtifactMigrationCoordinator {
    pub repo: PathBuf,
    pub project_id: String,
    pub state_root: PathBuf,
    pub registry_path: PathBuf,
    pub runs_db_path: Option<PathBuf>,
    pub graphify_path: Option<PathBuf>,
    pub device_id: String,
    pub provider: Option<String>,
    failure_injector: Option<MigrationInjector>,
    pub remote_timeout_seconds: f64,
    pub remote_name: Option<String>,
    program_bridge: Option<Vec<String>>,
    pub store: ArtifactStore,
    pub migration_root: PathBuf,
    pub journal_path: PathBuf,
    pub preview_path: PathBuf,
    pub registry_backup_path: PathBuf,
    pub legacy_backup_path: PathBuf,
    pub graphify_backup_path: PathBuf,
    pub graphify_rebuild_backup_path: PathBuf,
}

impl ArtifactMigrationCoordinator {
    pub fn new(
        repo_path: &Path,
        project_id: &str,
        state_root: &Path,
        registry_path: &Path,
        options: MigrationOptions,
    ) -> Result<Self> {
        let repo = resolve_user(&path_text(repo_path))?;
        let state_root = resolve_user(&path_text(state_root))?;
        let registry_path = resolve_user(&path_text(registry_path))?;
        let runs_db_path = options
            .runs_db_path
            .map(|path| resolve_user(&path_text(&path)))
            .transpose()?;
        let graphify_path = options
            .graphify_path
            .map(|path| resolve_user(&path_text(&path)))
            .transpose()?;
        let store = ArtifactStore::open(
            &repo,
            project_id,
            &state_root,
            StoreOptions {
                enabled: true,
                ..StoreOptions::default()
            },
        )?;
        let migration_root = store.project_state.join("legacy-migration");
        Ok(Self {
            journal_path: migration_root.join("journal.json"),
            preview_path: migration_root.join("preflight.json"),
            registry_backup_path: migration_root.join("registry-v2.before.json"),
            legacy_backup_path: migration_root.join("legacy-tree"),
            graphify_backup_path: migration_root.join("graphify.before.db"),
            graphify_rebuild_backup_path: migration_root.join("graphify.pre-rebuild.db"),
            migration_root,
            repo,
            project_id: project_id.to_string(),
            state_root,
            registry_path,
            runs_db_path,
            graphify_path,
            device_id: options.device_id,
            provider: options.provider,
            failure_injector: options.failure_injector,
            remote_timeout_seconds: options.remote_timeout_seconds.max(1.0),
            remote_name: options.remote_name,
            program_bridge: options.program_bridge,
            store,
        })
    }

    // -- public workflow -------------------------------------------------------------

    /// The complete preflight, without writing any state.
    pub fn preview(&self) -> Result<MigrationPreview> {
        let mut blockers = Vec::new();
        let mut preview = MigrationPreview {
            project_id: self.project_id.clone(),
            repo_path: path_text(&self.repo),
            ..MigrationPreview::default()
        };
        let mut remote = Dict::new();
        remote.insert("mode", "local_only");
        remote.insert("name", Value::Null);
        remote.insert("state", "not_configured");

        let identity = (|| -> Result<()> {
            preview.source_branch =
                self.git_text(&["symbolic-ref", "--quiet", "--short", "HEAD"])?;
            preview.source_head = self
                .optional_git_text(&["rev-parse", "--verify", "HEAD"])?
                .unwrap_or_default();
            preview.common_directory = self.absolute_git_path(&self.git_text(&[
                "rev-parse",
                "--path-format=absolute",
                "--git-common-dir",
            ])?);
            if self.git_text(&["rev-parse", "--is-bare-repository"])? == "true" {
                block(
                    &mut blockers,
                    "bare_repository",
                    "The selected project is a bare repository.",
                    "Select a normal registered worktree and rerun preflight.",
                );
            }
            preview.default_branch = self.default_branch(&preview.source_branch)?;
            preview.git = self.git_state(&preview.source_branch, &preview.source_head)?;
            Ok(())
        })();
        if let Err(error) = identity {
            block(
                &mut blockers,
                "git_identity",
                &error.message,
                "Repair the repository identity or select the correct registered worktree.",
            );
        }

        match self.registry_record(&preview.common_directory) {
            Ok(record) => {
                let found = self.remote_preflight(&record);
                preview.registry_record = record;
                match found {
                    Ok(found) => remote = found,
                    Err(error) if error.kind.is_migration() => block(
                        &mut blockers,
                        "registry_identity",
                        &error.message,
                        error.recovery.as_deref().unwrap_or_default(),
                    ),
                    Err(error) => return Err(error),
                }
            }
            Err(error) if error.kind.is_migration() => block(
                &mut blockers,
                "registry_identity",
                &error.message,
                error.recovery.as_deref().unwrap_or_default(),
            ),
            Err(error) => return Err(error),
        }

        match self.legacy_manifest() {
            Ok(manifest) => preview.manifest = manifest,
            Err(error) if error.kind.is_migration() => block(
                &mut blockers,
                "legacy_tree",
                &error.message,
                error.recovery.as_deref().unwrap_or_default(),
            ),
            Err(error) => return Err(error),
        }

        match self.run_references() {
            Ok(references) => {
                let active: Vec<String> = references
                    .iter()
                    .filter(|row| {
                        row.get("state")
                            .and_then(Value::as_str)
                            .is_some_and(|state| ACTIVE_RUN_STATES.contains(&state))
                    })
                    .map(|row| {
                        row.get("id")
                            .map(Value::py_str)
                            .unwrap_or_else(|| "None".to_string())
                    })
                    .collect();
                if !active.is_empty() {
                    block(
                        &mut blockers,
                        "active_runs",
                        &format!(
                            "Project has active or review-blocking runs: {}.",
                            active.join(", ")
                        ),
                        "Drain, finish, cancel, or explicitly reconcile those runs before migration.",
                    );
                }
                preview.run_references = references;
            }
            Err(error) if error.kind.is_migration() => block(
                &mut blockers,
                "run_ledger",
                &error.message,
                error.recovery.as_deref().unwrap_or_default(),
            ),
            Err(error) => return Err(error),
        }

        match self.program_references() {
            Ok(references) => preview.program_references = references,
            Err(error) if error.kind.is_migration() => block(
                &mut blockers,
                "program_store",
                &error.message,
                error.recovery.as_deref().unwrap_or_default(),
            ),
            Err(error) => return Err(error),
        }

        if !preview.manifest.is_empty()
            && !preview.source_branch.is_empty()
            && let Some(local_ref) =
                self.optional_git_text(&["rev-parse", "--verify", ARTIFACT_REF])?
        {
            let journal = self.load_journal();
            let expected = get_text(&journal, "artifact_commit");
            let expected_manifest = get_text(&journal, "manifest_digest");
            let digest = json_digest(&Value::Dict(preview.manifest.clone()));
            if local_ref != expected || digest != expected_manifest {
                block(
                    &mut blockers,
                    "unexpected_artifact_ref",
                    &format!(
                        "{ARTIFACT_REF} already exists at {local_ref} without a matching migration journal."
                    ),
                    "Stop and reconcile the existing artifact identity/history; do not overwrite the ref.",
                );
            }
        }

        preview.manifest_digest = if preview.manifest.is_empty() {
            String::new()
        } else {
            json_digest(&Value::Dict(preview.manifest.clone()))
        };
        preview.remote = remote;
        preview.blockers = blockers;
        Ok(preview)
    }

    /// Run or resume the migration; source cutover always needs explicit
    /// confirmation.
    pub fn migrate(
        &self,
        confirm_source_cleanup: bool,
        confirm_first_push: bool,
    ) -> Result<MigrationResult> {
        if !confirm_source_cleanup {
            return Err(blocked(
                "Source cleanup was not explicitly confirmed; no migration write was made.",
                "Review the preflight manifest and rerun with source cleanup confirmed.",
            ));
        }
        self.store.with_writer_lock(|| {
            let mut journal = self.load_journal();
            if journal
                .get("stage")
                .is_some_and(|stage| stage.is_str("complete"))
            {
                return self.result_from_journal(&journal, true);
            }
            if journal
                .get("stage")
                .is_some_and(|stage| stage.is_str("rolled_back"))
            {
                return Err(blocked_with(
                    "This migration journal is rolled back.",
                    "Start a new explicitly reviewed migration after resolving the rollback state.",
                    &journal,
                ));
            }

            if journal.is_empty() {
                let preview = self.preview()?;
                if !preview.can_migrate() {
                    return Err(blocked_with(
                        "Migration preflight found blockers.",
                        "Resolve every reported blocker, then rerun the read-only preflight.",
                        &preview.as_dict(),
                    ));
                }
                journal = self.begin_journal(&preview)?;
                self.inject("after_preflight_journal")?;
            } else {
                self.validate_resume_identity(&journal, false)?;
            }

            self.ensure_backups(&mut journal)?;
            let stage = |journal: &Dict| -> String {
                journal
                    .truthy("stage")
                    .map_or_else(|| "preflight_recorded".to_string(), Value::py_str)
            };
            if stage(&journal) == "preflight_recorded" {
                self.bootstrap(&mut journal, confirm_first_push)?;
                self.inject("after_artifact_bootstrap")?;
            }
            if get_str(&journal, "stage") == "bootstrap_verified" {
                self.finish_remote(&mut journal, confirm_first_push)?;
                self.inject("after_remote")?;
            }
            if get_str(&journal, "stage") == "remote_verified" {
                self.source_cutover(&mut journal)?;
                self.inject("after_source_commit")?;
            }
            if get_str(&journal, "stage") == "source_cutover" {
                let head = self.store.recover()?;
                journal.insert("artifact_commit", head);
                journal.insert("stage", "materialized");
                self.write_journal(&journal)?;
                self.inject("after_materialize")?;
            }
            if get_str(&journal, "stage") == "materialized" {
                journal = self.migrate_program_and_rebuild(journal)?;
                self.inject("after_program_export")?;
            }
            if get_str(&journal, "stage") == "program_rebuilt" {
                journal.insert("retention_preview", self.retention_preview()?);
                journal.insert("artifact_commit", self.store.snapshot()?.commit_id);
                journal.insert("stage", "retention_previewed");
                self.write_journal(&journal)?;
            }
            if get_str(&journal, "stage") == "retention_previewed" {
                if get_dict(&journal, "remote_result")
                    .get("mode")
                    .is_some_and(|mode| mode.is_str("enabled"))
                {
                    let pushed = self.push_current_artifact(&journal, false)?;
                    journal.insert("remote_result", pushed);
                }
                journal.insert("completed_at", now_iso());
                let rollback = self.rollback_instructions(&journal);
                journal.insert("rollback", rollback);
                journal.insert("stage", "complete");
                self.inject("before_complete")?;
                self.write_journal(&journal)?;
            }
            self.result_from_journal(&journal, false)
        })
    }

    /// Roll back writer ownership while retaining all artifact history.
    pub fn rollback(&self) -> Result<RollbackResult> {
        self.store.with_writer_lock(|| {
            let mut journal = self.load_journal();
            if journal.is_empty() {
                return Err(blocked(
                    "No migration journal exists for this project.",
                    "Run migration preflight first; there is no recorded rollback authority.",
                ));
            }
            if journal.get("stage").is_some_and(|stage| stage.is_str("rolled_back")) {
                return Ok(RollbackResult {
                    project_id: self.project_id.clone(),
                    stage: "rolled_back".to_string(),
                    artifact_ref_retained: true,
                    source_commit: journal
                        .get("rollback_source_commit")
                        .filter(|value| !matches!(value, Value::Null))
                        .map(Value::py_str),
                    journal_path: path_text(&self.journal_path),
                    idempotent: true,
                });
            }
            self.validate_resume_identity(&journal, true)?;
            let mut source_commit = None;
            let cutover_happened =
                get_bool(&journal, "source_cutover_complete") || get_bool(&journal, "source_commit");
            if cutover_happened {
                let expected_artifact = get_text(&journal, "artifact_commit");
                let current_artifact = self.optional_git_text(&["rev-parse", "--verify", ARTIFACT_REF])?;
                if current_artifact.as_deref() != Some(expected_artifact.as_str()) {
                    return Err(reconciliation(
                        "Artifact history advanced after migration; rollback cannot choose between writes.",
                        "Reconcile immutable Relay event IDs, then record the chosen artifact head explicitly.",
                        &journal,
                    ));
                }
                if !is_dir(&self.legacy_backup_path) {
                    return Err(blocked_with(
                        "The recorded legacy-tree backup is missing.",
                        "Restore the exact journal backup before attempting rollback.",
                        &journal,
                    ));
                }
                source_commit = self.restore_source_commit(&journal)?;
                self.restore_legacy_materialization()?;
                self.remove_local_exclude()?;
                remove_if_present(&self.store.metadata_path)?;
                remove_if_present(&self.store.journal_path)?;
            }
            self.restore_registry_backup()?;
            journal.insert("stage", "rolled_back");
            journal.insert("rolled_back_at", now_iso());
            journal.insert("rollback_source_commit", source_commit.clone());
            journal.insert("artifact_ref_retained", true);
            journal.insert("remote_ref_retained", true);
            self.write_journal(&journal)?;
            Ok(RollbackResult {
                project_id: self.project_id.clone(),
                stage: "rolled_back".to_string(),
                artifact_ref_retained: true,
                source_commit,
                journal_path: path_text(&self.journal_path),
                idempotent: false,
            })
        })
    }

    // -- preflight -----------------------------------------------------------------

    fn registry_record(&self, common_directory: &str) -> Result<Dict> {
        let recovery = "Restore a valid registry-v2 primary or backup before migration.";
        let bytes = fs::read(&self.registry_path).map_err(|error| {
            blocked(
                format!(
                    "Registry-v2 cannot be read: {}",
                    os_error(&error, &self.registry_path)
                ),
                recovery,
            )
        })?;
        let text = decode(&bytes)
            .map_err(|error| blocked(format!("Registry-v2 cannot be read: {error}"), recovery))?;
        let document = json::parse(&pystr::universal_newlines(text))
            .ok_or_else(|| blocked("Registry-v2 cannot be read: Expecting value", recovery))?;
        let document = match document {
            Value::Dict(dict)
                if dict
                    .get("schema_version")
                    .is_some_and(|version| json::py_eq(version, &Value::Int(2))) =>
            {
                dict
            }
            _ => {
                return Err(blocked(
                    "Migration requires registry-v2 schema 2.",
                    "Complete RR-281 registry migration and re-confirm this project first.",
                ));
            }
        };
        let projects = document
            .get("projects")
            .and_then(Value::as_list)
            .unwrap_or_default();
        let matches: Vec<&Dict> = projects
            .iter()
            .filter_map(Value::as_dict)
            .filter(|record| {
                record
                    .get("project_id")
                    .is_some_and(|id| id.is_str(&self.project_id))
            })
            .collect();
        if matches.len() != 1 {
            return Err(blocked(
                format!(
                    "Registry-v2 has {} records for project {}.",
                    matches.len(),
                    pystr::repr(&self.project_id)
                ),
                "Resolve the missing or duplicate immutable project identity.",
            ));
        }
        let record = matches[0].clone();
        if !record
            .get("availability")
            .is_some_and(|value| value.is_str("available"))
        {
            return Err(blocked(
                format!(
                    "Registered project availability is {}.",
                    value_repr(record.get("availability"))
                ),
                "Locate/regrant the project and confirm it is available before migration.",
            ));
        }
        let resolved = record.text("last_resolved_path");
        if resolved.is_empty() || resolve_user(&resolved)? != self.repo {
            return Err(blocked(
                "Registry-v2 resolved path does not identify the selected repository.",
                "Re-resolve the registered project path and reconfirm project scope.",
            ));
        }
        let fingerprint = record.string("git_common_directory_fingerprint");
        if !fingerprint.starts_with("git-common-v1:") || common_directory.is_empty() {
            return Err(blocked(
                "Registry-v2 has no confirmed Git common-directory identity.",
                "Re-register the project to refresh its common-directory fingerprint.",
            ));
        }
        let Some(remote) = record.get("remote").and_then(Value::as_dict) else {
            return Err(blocked(
                "Registry-v2 remote metadata is missing.",
                "Choose local-only or an explicit existing remote in Workspace.",
            ));
        };
        let artifact_ref = if remote.get("artifactRef").is_some() {
            remote.get("artifactRef")
        } else {
            remote.get("artifact_ref")
        };
        if !artifact_ref.is_some_and(|value| value.is_str(ARTIFACT_REF)) {
            return Err(blocked(
                format!(
                    "Registry-v2 selects unsupported artifact ref {}.",
                    value_repr(artifact_ref)
                ),
                &format!("Set the project artifact ref to {ARTIFACT_REF}."),
            ));
        }
        Ok(record)
    }

    fn legacy_manifest(&self) -> Result<Dict> {
        let root = self.repo.join(".orchestrator");
        if is_symlink(&root) || !is_dir(&root) {
            return Err(blocked(
                "Legacy .orchestrator must be a normal directory.",
                "Replace unsupported symlink/non-directory input with the reviewed legacy tree.",
            ));
        }
        let relative_of = |path: &Path| -> String {
            path.strip_prefix(&self.repo)
                .map_or_else(|_| path_text(path), path_text)
        };
        let mut files: BTreeMap<String, Dict> = BTreeMap::new();
        let mut contents: BTreeMap<String, Vec<u8>> = BTreeMap::new();
        for (directory, directories, filenames) in walk(&root)? {
            for name in &directories {
                let child = directory.join(name);
                if is_symlink(&child) {
                    return Err(blocked(
                        format!("Unsupported symlink directory: {}", relative_of(&child)),
                        "Replace the symlink with reviewed regular artifact files.",
                    ));
                }
            }
            for name in &filenames {
                let path = directory.join(name);
                let relative = relative_of(&path);
                if is_symlink(&path) || !is_file(&path) {
                    return Err(blocked(
                        format!("Unsupported non-regular legacy path: {relative}"),
                        "Replace symlinks/submodules/special files with reviewed regular files.",
                    ));
                }
                validate_legacy_path(&relative)?;
                let content = fs::read(&path).map_err(|error| io_error(error, &path))?;
                let metadata = fs::metadata(&path).map_err(|error| io_error(error, &path))?;
                let mut entry = Dict::new();
                entry.insert("sha256", sha256(&content));
                entry.insert("bytes", content.len() as i64);
                entry.insert(
                    "mtime_ns",
                    metadata.mtime() * 1_000_000_000 + metadata.mtime_nsec(),
                );
                entry.insert("tracked", false);
                files.insert(relative.clone(), entry);
                contents.insert(relative, content);
            }
        }
        let Some(config_bytes) = contents.get(".orchestrator/config.toml") else {
            return Err(blocked(
                "Legacy tree has no config.toml.",
                "Restore a valid legacy config with prefix and next_id.",
            ));
        };

        for (path, mode) in self.tracked_orchestrator_entries()? {
            if mode != "100644" {
                return Err(blocked(
                    format!("Tracked legacy path has unsupported Git mode {mode}: {path}"),
                    "Replace symlink/gitlink modes with reviewed regular files before migration.",
                ));
            }
            if let Some(entry) = files.get_mut(&path) {
                entry.insert("tracked", true);
            }
        }

        let malformed = |message: String| {
            blocked(
                format!("Legacy config is malformed: {message}"),
                "Repair config.toml without discarding prefix/next_id evidence.",
            )
        };
        let config_text = decode(config_bytes).map_err(|error| malformed(error.message))?;
        let config = toml::loads(config_text).map_err(|error| malformed(error.message))?;
        let unknown: BTreeSet<&str> = config
            .iter()
            .map(|(key, _)| key)
            .filter(|key| !LEGACY_CONFIG_KEYS.contains(key))
            .collect();
        if !unknown.is_empty() {
            return Err(blocked(
                format!(
                    "Legacy config contains ambiguous fields: {}",
                    unknown.into_iter().collect::<Vec<_>>().join(", ")
                ),
                "Review those fields and reconcile any prior artifact rollout before migration.",
            ));
        }
        // `str(config.get("prefix") or "").strip()`
        let prefix = match config.get("prefix") {
            Some(toml::Value::String(text)) => Some(json::py_strip(text).to_string()),
            Some(toml::Value::Integer(0)) | Some(toml::Value::Boolean(false)) | None => {
                Some(String::new())
            }
            Some(toml::Value::Integer(number)) => Some(number.to_string()),
            Some(toml::Value::Boolean(true)) => Some("True".to_string()),
            Some(_) => None,
        };
        let next_id = match config.get("next_id") {
            Some(toml::Value::Integer(number)) if *number > 0 => Some(*number),
            _ => None,
        };
        let (Some(prefix), Some(next_id)) = (prefix, next_id) else {
            return Err(legacy_config_blocked());
        };
        if prefix.is_empty() || !prefix.chars().all(char::is_alphanumeric) {
            return Err(legacy_config_blocked());
        }

        let mut ticket_ids: BTreeSet<String> = BTreeSet::new();
        let mut dependencies = Dict::new();
        let mut referenced_attachments = Dict::new();
        let mut projected: BTreeMap<String, Dict> = BTreeMap::new();
        for (relative, content) in &contents {
            let path_parts = parts(relative);
            if path_parts.len() != 2 || suffix_of(relative) != ".md" {
                continue;
            }
            let ticket_id = stem_of(relative).to_string();
            let malformed_ticket = |message: String| {
                blocked(
                    format!("Malformed ticket {relative}: {message}"),
                    "Repair the ticket frontmatter/body and rerun preflight.",
                )
            };
            let legacy =
                legacy_ticket_content(content).map_err(|error| malformed_ticket(error.message))?;
            let text = decode(&legacy).map_err(|error| malformed_ticket(error.message))?;
            let ticket = tickets::parse(text).map_err(|error| malformed_ticket(error.message))?;
            if ticket.id != ticket_id || ticket_ids.contains(&ticket_id) {
                return Err(blocked(
                    format!("Ticket identity does not match its unique filename: {relative}"),
                    "Resolve duplicate/mismatched ticket IDs without inventing provenance.",
                ));
            }
            ticket_ids.insert(ticket_id.clone());
            dependencies.insert(&ticket_id, strings(&ticket.depends_on));
            let references = attachment_references(&ticket.body);
            referenced_attachments.insert(&ticket_id, strings(&references));
            for reference in &references {
                let expected = format!(".orchestrator/{reference}");
                if !contents.contains_key(&expected) {
                    return Err(blocked(
                        format!("Ticket {ticket_id} references missing attachment {reference}."),
                        "Restore the referenced bytes or remove the reviewed broken reference.",
                    ));
                }
                let reference_parts = parts(reference);
                if reference_parts.len() != 3 || reference_parts[1] != ticket_id {
                    return Err(blocked(
                        format!(
                            "Ticket {ticket_id} references attachment outside its owned directory: {reference}"
                        ),
                        "Move the attachment under attachments/<ticket-id>/ and update the ticket.",
                    ));
                }
            }
            let mtime_ns = files[relative]
                .get("mtime_ns")
                .and_then(Value::py_int)
                .unwrap_or(0);
            let activity =
                front_value(content, "activity_at").unwrap_or_else(|| mtime_iso(mtime_ns));
            let artifact_id = store::ticket_front_matter_value(content, "artifact_id")
                .unwrap_or_else(|| artifact_id_for(&self.project_id, &ticket_id));
            let migrated = set_frontmatter_defaults(content, &artifact_id, &activity)?;
            let mut entry = Dict::new();
            entry.insert(
                "source_sha256",
                files[relative]
                    .get("sha256")
                    .cloned()
                    .unwrap_or(Value::Null),
            );
            entry.insert("artifact_sha256", sha256(&migrated));
            entry.insert("artifact_id", artifact_id.as_str());
            entry.insert("activity_at", activity.as_str());
            projected.insert(relative.clone(), entry);
            if migrated.len() > store::TICKET_MAX_BYTES {
                return Err(blocked(
                    format!(
                        "Ticket {ticket_id} exceeds the artifact size limit after identity anchors."
                    ),
                    "Refine or split the ticket without discarding durable evidence.",
                ));
            }
            if let Err(error) = store::reject_secrets(&migrated, &format!("ticket {ticket_id}")) {
                if !error.kind.is_store_error() {
                    return Err(error);
                }
                return Err(blocked(
                    format!("Ticket {ticket_id} failed the artifact privacy gate: {error}"),
                    "Remove/rotate the sensitive value before any Git artifact bootstrap.",
                ));
            }
        }

        for (relative, content) in &contents {
            let path_parts = parts(relative);
            if path_parts.len() == 4 && path_parts[..2] == [".orchestrator", "attachments"] {
                let owner = path_parts[2];
                if !ticket_ids.contains(owner) {
                    return Err(blocked(
                        format!("Attachment has no owning ticket: {relative}"),
                        "Restore its ticket or remove the reviewed orphan attachment.",
                    ));
                }
                let name = path_parts[3];
                let checked = store::attachment_mime_for_filename(name)
                    .and_then(|mime| store::validate_attachment(name, mime, content));
                if let Err(error) = checked {
                    if !error.kind.is_store_error() {
                        return Err(error);
                    }
                    return Err(blocked(
                        format!("Unsupported attachment {relative}: {error}"),
                        "Move unsupported/private/oversized data outside Relay artifact storage.",
                    ));
                }
            }
        }

        if let Some(index) = contents.get(".orchestrator/archive-index.jsonl")
            && let Err(error) = store::validate_archive_index(index)
        {
            if !error.kind.is_store_error() {
                return Err(error);
            }
            return Err(blocked(
                format!("Legacy archive catalog is invalid: {error}"),
                "Repair the catalog from verified historical evidence before migration.",
            ));
        }
        for (relative, content) in &contents {
            let path_parts = parts(relative);
            if path_parts.len() == 4
                && path_parts[..3] == [".orchestrator", "program", "events"]
                && let Err(error) = self.store.prepare_program_event(stem_of(relative), content)
            {
                if !error.kind.is_store_error() {
                    return Err(error);
                }
                return Err(blocked(
                    format!("Legacy Program event {relative} is invalid: {error}"),
                    "Reconcile the durable Program event identity/privacy fields.",
                ));
            }
        }

        let config_artifact = self.artifact_config(&prefix, next_id, "local_only", None)?;
        let mut config_entry = Dict::new();
        config_entry.insert(
            "source_sha256",
            files[".orchestrator/config.toml"]
                .get("sha256")
                .cloned()
                .unwrap_or(Value::Null),
        );
        config_entry.insert("artifact_sha256", sha256(&config_artifact));
        projected.insert(".orchestrator/config.toml".to_string(), config_entry);
        if !contents.contains_key(".orchestrator/archive-index.jsonl") {
            let mut anchor = Dict::new();
            anchor.insert("source_sha256", Value::Null);
            anchor.insert("artifact_sha256", sha256(b""));
            anchor.insert("catalog_anchor", true);
            projected.insert(".orchestrator/archive-index.jsonl".to_string(), anchor);
        }

        let mut files_dict = Dict::new();
        for (path, entry) in &files {
            files_dict.insert(path, entry.clone());
        }
        let mut projected_dict = Dict::new();
        for (path, entry) in projected {
            projected_dict.insert(&path, entry);
        }
        let mut legacy_config = Dict::new();
        legacy_config.insert("prefix", prefix.as_str());
        legacy_config.insert("next_id", next_id);
        let mut manifest = Dict::new();
        manifest.insert("schema_version", MIGRATION_SCHEMA_VERSION);
        manifest.insert("project_id", self.project_id.as_str());
        manifest.insert("source_tree_sha256", file_manifest_digest(&files_dict));
        manifest.insert("files", files_dict);
        manifest.insert(
            "tickets",
            Value::List(ticket_ids.iter().map(|id| Value::Str(id.clone())).collect()),
        );
        manifest.insert("dependencies", dependencies);
        manifest.insert("referenced_attachments", referenced_attachments);
        manifest.insert("projected", projected_dict);
        manifest.insert("legacy_config", legacy_config);
        Ok(manifest)
    }

    fn run_references(&self) -> Result<Vec<Dict>> {
        let Some(path) = self.runs_db_path.as_ref().filter(|path| path.exists()) else {
            return Ok(Vec::new());
        };
        let safe_fields = [
            "id",
            "ticket_id",
            "state",
            "attempt",
            "started_at",
            "ended_at",
            "activity_at",
            "provider_key",
            "execution_mode",
        ];
        let read = || -> rusqlite::Result<Vec<Dict>> {
            let connection = open_read_only(path)?;
            let table: Option<i64> = connection
                .query_row(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='runs'",
                    [],
                    |row| row.get(0),
                )
                .map(Some)
                .or_else(|error| match error {
                    rusqlite::Error::QueryReturnedNoRows => Ok(None),
                    other => Err(other),
                })?;
            if table.is_none() {
                return Err(sqlite_message("runs table is missing"));
            }
            let mut statement =
                connection.prepare("SELECT * FROM runs WHERE repo_path = ? ORDER BY id")?;
            let columns: Vec<String> = statement.column_names().map(str::to_string).collect();
            let mut rows = statement.query([path_text(&self.repo)])?;
            let mut result = Vec::new();
            while let Some(row) = rows.next()? {
                let mut record = Dict::new();
                for field in safe_fields {
                    if let Some(index) = columns.iter().position(|name| name == field) {
                        record.insert(field, sqlite_value(row.get_ref(index)?));
                    }
                }
                result.push(record);
            }
            Ok(result)
        };
        read().map_err(|error| {
            blocked(
                format!(
                    "Runs ledger cannot prove quiescence: {}",
                    sqlite_text(&error)
                ),
                "Repair or restore runs.db, then verify no active/review-blocking run remains.",
            )
        })
    }

    fn program_references(&self) -> Result<Vec<Dict>> {
        let Some(path) = self.graphify_path.as_ref().filter(|path| path.exists()) else {
            return Ok(Vec::new());
        };
        let read = || -> rusqlite::Result<Vec<Dict>> {
            let connection = open_read_only(path)?;
            let project: Option<String> = match connection.query_row(
                "SELECT id FROM graph_nodes WHERE kind='Project' AND stable_key=?",
                [format!("repo:{}", path_text(&self.repo))],
                |row| Ok(sqlite_value(row.get_ref(0)?).py_str()),
            ) {
                Ok(id) => Some(id),
                Err(rusqlite::Error::QueryReturnedNoRows) => None,
                Err(error) => return Err(error),
            };
            let Some(project) = project else {
                return Ok(Vec::new());
            };
            let mut statement = connection.prepare(
                "SELECT id, kind, stable_key, body_json FROM graph_nodes \
                 WHERE project_id=? AND kind IN ('ProgramEvent','Decision','Risk','Idea','Status') \
                 ORDER BY kind, stable_key",
            )?;
            let mut rows = statement.query([project])?;
            let mut result = Vec::new();
            while let Some(row) = rows.next()? {
                let mut record = Dict::new();
                record.insert("id", sqlite_value(row.get_ref(0)?));
                record.insert("kind", sqlite_value(row.get_ref(1)?));
                record.insert("stable_key", sqlite_value(row.get_ref(2)?));
                record.insert(
                    "body_sha256",
                    sha256(sqlite_value(row.get_ref(3)?).py_str().as_bytes()),
                );
                result.push(record);
            }
            Ok(result)
        };
        read().map_err(|error| {
            blocked(
                format!(
                    "Graphify project records cannot be inspected: {}",
                    sqlite_text(&error)
                ),
                "Restore the Graphify backup or explicitly rebuild it before migration.",
            )
        })
    }

    fn remote_preflight(&self, registry_record: &Dict) -> Result<Dict> {
        let mut metadata = get_dict(registry_record, "remote");
        if let Some(name) = &self.remote_name {
            metadata = Dict::new();
            metadata.insert("mode", "enabled");
            metadata.insert("remoteName", name.as_str());
        }
        let mode = metadata
            .truthy("mode")
            .map_or_else(|| "local_only".to_string(), Value::py_str);
        let name = if metadata.get("remoteName").is_some() {
            metadata.get("remoteName")
        } else {
            metadata.get("remote_name")
        };
        if mode == "local_only" || !name.is_some_and(Value::truthy) {
            let mut local = Dict::new();
            local.insert("mode", "local_only");
            local.insert("name", Value::Null);
            local.insert("state", "not_configured");
            return Ok(local);
        }
        let name = name.map(Value::py_str).unwrap_or_default();
        if !is_remote_name(&name) {
            return Err(blocked(
                format!("Configured remote name is invalid: {}", pystr::repr(&name)),
                "Choose an existing safe Git remote name.",
            ));
        }
        let remotes = self.remote_records()?;
        let Some(record) = remotes
            .iter()
            .find(|entry| entry.get("name").is_some_and(|value| value.is_str(&name)))
        else {
            return Err(blocked(
                format!(
                    "Configured artifact remote {} does not exist.",
                    pystr::repr(&name)
                ),
                "Restore that remote or switch the project to local-only before migration.",
            ));
        };
        let (fetch_url, push_url) =
            configured_remote_urls(&self.store, &name).map_err(|error| {
                if error.kind.is_store_error() {
                    blocked(
                        error.message.clone(),
                        "Select one existing archive push destination before migration.",
                    )
                } else {
                    error
                }
            })?;
        let output = self.run_git(
            &["ls-remote", "--refs", &name, ARTIFACT_REF],
            &[],
            None,
            Some(self.remote_timeout_seconds),
            &[0],
        )?;
        let output = text_of(&output.stdout);
        let (state, oid) = if output.is_empty() {
            ("ref_absent", Value::Null)
        } else {
            let fields: Vec<&str> = output.split_whitespace().collect();
            if fields.len() != 2 || fields[1] != ARTIFACT_REF || !is_hex_oid(fields[0]) {
                return Err(blocked(
                    "Remote artifact discovery returned an ambiguous result.",
                    "Inspect the remote ref manually and resolve it before migration.",
                ));
            }
            ("ref_present", Value::Str(fields[0].to_string()))
        };
        let mut result = Dict::new();
        result.insert("mode", mode.as_str());
        result.insert("name", name.as_str());
        result.insert("state", state);
        result.insert("oid", oid);
        result.insert(
            "locator",
            record.get("locator").cloned().unwrap_or(Value::Null),
        );
        result.insert("url_sha256", sha256(fetch_url.as_bytes()));
        result.insert("push_url_sha256", sha256(push_url.as_bytes()));
        Ok(result)
    }

    // -- mutation stages ---------------------------------------------------------

    fn begin_journal(&self, preview: &MigrationPreview) -> Result<Dict> {
        fs::create_dir_all(&self.migration_root)
            .map_err(|error| io_error(error, &self.migration_root))?;
        let dicts = |items: &[Dict]| Value::List(items.iter().cloned().map(Value::Dict).collect());
        let mut rollback = Dict::new();
        rollback.insert(
            "before_cutover",
            "Retain the orphan artifact ref, restore registry backup, and keep the legacy writer authoritative.",
        );
        rollback.insert(
            "after_cutover",
            "Freeze writers, reconcile event IDs if the artifact head advanced, then restore the exact legacy backup in a new source commit.",
        );
        let mut journal = Dict::new();
        journal.insert("schema_version", MIGRATION_SCHEMA_VERSION);
        journal.insert("project_id", self.project_id.as_str());
        journal.insert("repo_path", path_text(&self.repo));
        journal.insert("stage", "preflight_recorded");
        journal.insert("started_at", now_iso());
        journal.insert("manifest", preview.manifest.clone());
        journal.insert("manifest_digest", preview.manifest_digest.as_str());
        journal.insert("source_branch", preview.source_branch.as_str());
        journal.insert("default_branch", preview.default_branch.as_str());
        journal.insert("source_head_before", preview.source_head.as_str());
        journal.insert("common_directory", preview.common_directory.as_str());
        journal.insert("git_before", preview.git.clone());
        journal.insert("registry_record", preview.registry_record.clone());
        journal.insert("run_references", dicts(&preview.run_references));
        journal.insert("program_references", dicts(&preview.program_references));
        journal.insert("remote_preflight", preview.remote.clone());
        journal.insert("rollback", rollback);
        write_json(&self.preview_path, &preview.as_dict())?;
        self.write_journal(&journal)?;
        Ok(journal)
    }

    fn ensure_backups(&self, journal: &mut Dict) -> Result<()> {
        if !self.registry_backup_path.exists() {
            if let Some(parent) = self.registry_backup_path.parent() {
                fs::create_dir_all(parent).map_err(|error| io_error(error, parent))?;
            }
            let bytes = fs::read(&self.registry_path)
                .map_err(|error| io_error(error, &self.registry_path))?;
            fs::write(&self.registry_backup_path, bytes)
                .map_err(|error| io_error(error, &self.registry_backup_path))?;
            chmod(&self.registry_backup_path, 0o600)?;
        }
        if !self.legacy_backup_path.exists() {
            let temporary = beside(&self.legacy_backup_path, &format!(".{}.tmp", random_hex()));
            self.copy_regular_tree(&self.repo.join(".orchestrator"), &temporary)?;
            fs::rename(&temporary, &self.legacy_backup_path)
                .map_err(|error| io_error(error, &self.legacy_backup_path))?;
        }
        let backup = self.directory_manifest(&self.legacy_backup_path, ".orchestrator");
        if file_manifest_digest(&backup)
            != get_str(&get_dict(journal, "manifest"), "source_tree_sha256")
        {
            return Err(blocked_with(
                "The recoverable legacy backup does not match the preflight manifest.",
                "Restore or recreate the exact backup before any cutover write.",
                journal,
            ));
        }
        journal.insert("registry_backup", path_text(&self.registry_backup_path));
        journal.insert("legacy_backup", path_text(&self.legacy_backup_path));
        self.write_journal(journal)
    }

    fn bootstrap(&self, journal: &mut Dict, confirm_first_push: bool) -> Result<()> {
        let remote = get_dict(journal, "remote_preflight");
        let state = get_str(&remote, "state");
        let remote_enabled = get_bool(&remote, "name")
            && (state == "ref_present" || (state == "ref_absent" && confirm_first_push));
        let remote_name = get_str(&remote, "name");
        let (operations, projected_hashes) = self.bootstrap_operations(
            &get_dict(journal, "manifest"),
            if remote_enabled {
                "enabled"
            } else {
                "local_only"
            },
            remote_enabled.then_some(remote_name.as_str()),
        )?;
        let (artifact_commit, adopted) = if state == "ref_present" {
            let remote_files = self.inspect_remote_artifact(&remote_name)?;
            verify_projected_hashes(&remote_files, &projected_hashes)?;
            self.run_git(
                &[
                    "fetch",
                    "--no-tags",
                    &remote_name,
                    &format!("{ARTIFACT_REF}:{ARTIFACT_REF}"),
                ],
                &[],
                None,
                Some(self.remote_timeout_seconds),
                &[0],
            )?;
            (
                self.git_text(&["rev-parse", "--verify", ARTIFACT_REF])?,
                true,
            )
        } else {
            let digest = get_str(journal, "manifest_digest");
            let mutation = Mutation {
                event_id: format!(
                    "migration-bootstrap:{}",
                    digest.chars().take(32).collect::<String>()
                ),
                actor_type: "migration".to_string(),
                device_id: self.device_id.clone(),
                operations,
                expected_base: None,
                provider: self.provider.clone(),
                summary: "Bootstrap reviewed legacy Relay artifacts".to_string(),
            };
            match self.store.bootstrap_legacy(&mutation) {
                Ok(write) => (write.commit_id, write.idempotent),
                Err(error) if error.kind.is_store_error() => {
                    return Err(blocked_with(
                        format!("Artifact bootstrap failed validation: {error}"),
                        "Correct the exact reported legacy content; do not bypass the typed writer.",
                        journal,
                    ));
                }
                Err(error) => return Err(error),
            }
        };
        let snapshot = self.store.snapshot()?;
        let files: BTreeMap<String, Vec<u8>> = snapshot.files.iter().cloned().collect();
        verify_projected_hashes(&files, &projected_hashes)?;
        let mut hashes = Dict::new();
        for (path, digest) in &projected_hashes {
            hashes.insert(path, digest.as_str());
        }
        journal.insert("stage", "bootstrap_verified");
        journal.insert("artifact_commit", artifact_commit);
        journal.insert("artifact_tree", snapshot.tree_id.as_str());
        journal.insert("artifact_file_hashes", hashes);
        journal.insert("artifact_adopted", adopted);
        journal.insert(
            "remote_mode",
            if remote_enabled {
                "enabled"
            } else {
                "local_only"
            },
        );
        self.write_journal(journal)
    }

    fn finish_remote(&self, journal: &mut Dict, confirm_first_push: bool) -> Result<()> {
        let remote = get_dict(journal, "remote_preflight");
        let mut result = Dict::new();
        if !journal
            .get("remote_mode")
            .is_some_and(|mode| mode.is_str("enabled"))
        {
            result.insert("mode", "local_only");
            result.insert("state", "not_pushed");
            result.insert(
                "reason",
                "No verified existing ref or explicitly confirmed first normal push.",
            );
        } else if remote
            .get("state")
            .is_some_and(|state| state.is_str("ref_present"))
        {
            result.insert("mode", "enabled");
            result.insert("state", "adopted_verified_ref");
            result.insert("remote", remote.get("name").cloned().unwrap_or(Value::Null));
            result.insert(
                "commit",
                journal
                    .get("artifact_commit")
                    .cloned()
                    .unwrap_or(Value::Null),
            );
        } else {
            if !confirm_first_push {
                return Err(blocked_with(
                    "The first artifact push was not explicitly confirmed.",
                    "Keep local-only, or rerun with a reviewed first normal push confirmation.",
                    journal,
                ));
            }
            result = self.push_current_artifact(journal, true)?;
        }
        self.write_registry_mode(&get_str(&result, "mode"), remote.get("name"))?;
        journal.insert("remote_result", result);
        journal.insert("stage", "remote_verified");
        self.write_journal(journal)
    }

    fn source_cutover(&self, journal: &mut Dict) -> Result<()> {
        self.revalidate_unrelated_source(journal, false)?;
        let manifest = get_dict(journal, "manifest");
        let current = self.directory_manifest(&self.repo.join(".orchestrator"), ".orchestrator");
        if file_manifest_digest(&current) != get_str(&manifest, "source_tree_sha256") {
            return Err(reconciliation(
                "Legacy tickets changed after migration preflight.",
                "Preserve the edits and reconcile them with the recorded archive before resuming.",
                journal,
            ));
        }
        let expected_head = get_str(journal, "source_head_before");
        let current_head = self
            .optional_git_text(&["rev-parse", "--verify", "HEAD"])?
            .unwrap_or_default();
        if self.git_text(&["symbolic-ref", "--quiet", "--short", "HEAD"])?
            != get_str(journal, "source_branch")
        {
            return Err(reconciliation(
                "Source branch changed after preflight.",
                "Return to the recorded source branch before resuming migration.",
                journal,
            ));
        }
        if current_head != expected_head {
            return Err(reconciliation(
                format!(
                    "Source HEAD changed after preflight: expected {expected_head}, found {current_head}."
                ),
                "Review the new source commit and restart migration with a fresh manifest.",
                journal,
            ));
        }
        let mut tracked_paths: Vec<String> = get_dict(&manifest, "files")
            .iter()
            .filter(|(_, meta)| meta.as_dict().is_some_and(|meta| get_bool(meta, "tracked")))
            .map(|(path, _)| path.to_string())
            .collect();
        tracked_paths.sort();
        let source_commit = if !tracked_paths.is_empty() && !expected_head.is_empty() {
            self.commit_source_without_orchestrator(
                &expected_head,
                &get_str(journal, "source_branch"),
                &tracked_paths,
                &get_str(journal, "manifest_digest"),
            )?
        } else {
            if !tracked_paths.is_empty() {
                // A new repository can accumulate tickets before its first
                // source commit: keep that unborn branch and every unrelated
                // staged file; only unstage the backed-up tickets.
                self.run_git(
                    &["update-index", "-z", "--force-remove", "--stdin"],
                    &[],
                    Some(&nul_list(&tracked_paths)),
                    None,
                    &[0],
                )?;
            }
            expected_head
        };
        journal.insert("source_commit", source_commit);
        journal.insert("source_cutover_complete", true);
        journal.insert("source_cleanup_paths", strings(&tracked_paths));
        journal.insert("stage", "source_cutover");
        self.write_journal(journal)?;
        self.revalidate_unrelated_source(journal, true)
    }

    fn migrate_program_and_rebuild(&self, mut journal: Dict) -> Result<Dict> {
        if self.graphify_path.is_some() {
            self.run_program_bridge()?;
            let journal = self.load_journal();
            if !journal
                .get("stage")
                .is_some_and(|stage| stage.is_str("program_rebuilt"))
            {
                return Err(Error::new(
                    ErrorKind::Runtime,
                    "Program migration bridge did not record the program_rebuilt stage",
                ));
            }
            return Ok(journal);
        }
        let mut report = Dict::new();
        report.insert("exported", 0_i64);
        report.insert("rebuild", Value::Null);
        journal.insert("program_migration", report);
        journal.insert("program_manifest", Dict::new());
        journal.insert("artifact_commit", self.store.snapshot()?.commit_id);
        journal.insert("stage", "program_rebuilt");
        self.write_journal(&journal)?;
        Ok(journal)
    }

    /// Runs Python's `_migrate_program_and_rebuild` on the recorded journal,
    /// under the writer lock this process already holds.
    fn run_program_bridge(&self) -> Result<()> {
        let command_line = self
            .program_bridge
            .clone()
            .unwrap_or_else(default_program_bridge);
        let Some((program, leading)) = command_line.split_first() else {
            return Err(Error::new(
                ErrorKind::Runtime,
                "Program migration bridge is not configured",
            ));
        };
        let mut command = Command::new(program);
        command.args(leading);
        let mut arguments: Vec<OsString> = vec![
            "--repo".into(),
            self.repo.clone().into(),
            "--project-id".into(),
            self.project_id.clone().into(),
            "--state-root".into(),
            self.state_root.clone().into(),
            "--registry".into(),
            self.registry_path.clone().into(),
            "--device-id".into(),
            self.device_id.clone().into(),
        ];
        if let Some(path) = &self.runs_db_path {
            arguments.extend(["--runs-db".into(), path.clone().into()]);
        }
        if let Some(path) = &self.graphify_path {
            arguments.extend(["--graphify".into(), path.clone().into()]);
        }
        if let Some(provider) = &self.provider {
            arguments.extend(["--provider".into(), provider.clone().into()]);
        }
        command.args(arguments);
        let output = run_process(command, None, None)
            .map_err(|error| {
                Error::new(
                    ErrorKind::Io,
                    format!("Program migration bridge could not start: {error}"),
                )
            })?
            .unwrap_or(ProcessOutput {
                status: -1,
                stdout: Vec::new(),
                stderr: Vec::new(),
            });
        let answer = std::str::from_utf8(&output.stdout)
            .ok()
            .and_then(|text| json::parse(pystr::strip(text)))
            .and_then(|value| value.as_dict().cloned());
        let Some(answer) = answer else {
            return Err(Error::new(
                ErrorKind::Runtime,
                format!(
                    "Program migration bridge failed ({}): {}",
                    output.status,
                    bounded_public_error(&output.stderr)
                ),
            ));
        };
        if get_bool(&answer, "ok") {
            return Ok(());
        }
        let kind = match get_str(&answer, "error").as_str() {
            "ArtifactMigrationBlocked" => ErrorKind::MigrationBlocked,
            "ArtifactMigrationReconciliationRequired" => ErrorKind::MigrationReconciliationRequired,
            "ArtifactMigrationInjectedFailure" => ErrorKind::MigrationInjectedFailure,
            "ArtifactMigrationError" => ErrorKind::Migration,
            "ArtifactValidationError" => ErrorKind::Validation,
            "ArtifactConcurrentUpdate" => ErrorKind::ConcurrentUpdate,
            "ArtifactEventCollision" => ErrorKind::EventCollision,
            "ArtifactStoreError" => ErrorKind::Store,
            "OSError" => ErrorKind::Io,
            _ => ErrorKind::Runtime,
        };
        let mut error = Error::new(kind, get_str(&answer, "message"));
        if kind.is_migration() {
            error = error
                .with_recovery(get_str(&answer, "recovery"))
                .with_report(
                    answer
                        .get("report")
                        .cloned()
                        .unwrap_or_else(|| Value::Dict(Dict::new())),
                );
        }
        Err(error)
    }

    fn retention_preview(&self) -> Result<Dict> {
        let manager = ArtifactRetentionManager::new(&self.store, RetentionOptions::default())?;
        let plan = manager.preview(None)?;
        let ids = |tickets: &[crate::retention::RetentionTicket]| -> Value {
            Value::List(
                tickets
                    .iter()
                    .map(|ticket| Value::Str(ticket.ticket_id.clone()))
                    .collect(),
            )
        };
        let mut overage = Dict::new();
        for ticket in &plan.exempt {
            overage.insert(&ticket.ticket_id, strings(&ticket.exemptions));
        }
        let mut materialized: Vec<String> = plan
            .nonterminal
            .iter()
            .chain(&plan.ranked_terminal)
            .filter(|ticket| ticket.materialized)
            .map(|ticket| ticket.ticket_id.clone())
            .collect();
        materialized.sort();
        let mut rollback = Dict::new();
        rollback.insert("artifact_head", plan.artifact_head.as_str());
        rollback.insert("materialized_ticket_ids", strings(&materialized));
        let mut result = Dict::new();
        result.insert("schema_version", plan.schema_version);
        result.insert("policy", plan.policy.as_str());
        result.insert("limit", plan.limit as i64);
        result.insert("artifact_head", plan.artifact_head.as_str());
        result.insert("evaluated_at", plan.evaluated_at.isoformat());
        result.insert("candidate_ids", strings(&plan.candidate_ids()));
        result.insert("ranked_terminal_ids", ids(&plan.ranked_terminal));
        result.insert(
            "retained_terminal_ids",
            strings(&plan.retained_terminal_ids()),
        );
        result.insert("nonterminal_ids", strings(&plan.nonterminal_ids()));
        result.insert("materialize_ids", strings(&plan.materialize_ids()));
        result.insert("temporary_overage", overage);
        result.insert("candidate_count", plan.candidates.len() as i64);
        result.insert(
            "retained_terminal_count",
            plan.retained_terminal.len() as i64,
        );
        result.insert("nonterminal_count", plan.nonterminal.len() as i64);
        result.insert("temporary_overage_count", plan.exempt.len() as i64);
        result.insert("transaction_state", "preview");
        result.insert("rollback", rollback);
        result.insert("committed", false);
        Ok(result)
    }

    // -- Git and rollback mechanics ------------------------------------------------

    fn commit_source_without_orchestrator(
        &self,
        parent: &str,
        branch: &str,
        paths: &[String],
        manifest_digest: &str,
    ) -> Result<String> {
        let temporary = TemporaryDirectory::new("relay-migration-index-")?;
        let index = path_text(&temporary.path.join("index"));
        let env = [("GIT_INDEX_FILE", index.as_str())];
        self.run_git(&["read-tree", parent], &env, None, None, &[0])?;
        self.run_git(
            &["update-index", "-z", "--force-remove", "--stdin"],
            &env,
            Some(&nul_list(paths)),
            None,
            &[0],
        )?;
        let tree = text_of(
            &self
                .run_git(&["write-tree"], &env, None, None, &[0])?
                .stdout,
        );
        let message = format!(
            "Stop tracking Relay artifact materialization\n\n\
             Relay-Migration-Project-ID: {}\n\
             Relay-Migration-Manifest: {manifest_digest}\n\
             Relay-Artifact-Commit: {}\n",
            self.project_id,
            self.store.snapshot()?.commit_id
        );
        let commit = text_of(
            &self
                .run_git(
                    &["commit-tree", &tree, "-p", parent],
                    &[],
                    Some(message.as_bytes()),
                    None,
                    &[0],
                )?
                .stdout,
        );
        drop(temporary);
        self.run_git(
            &[
                "update-ref",
                &format!("refs/heads/{branch}"),
                &commit,
                parent,
            ],
            &[],
            None,
            None,
            &[0],
        )?;
        self.run_git(
            &["update-index", "-z", "--force-remove", "--stdin"],
            &[],
            Some(&nul_list(paths)),
            None,
            &[0],
        )?;
        Ok(commit)
    }

    fn restore_source_commit(&self, journal: &Dict) -> Result<Option<String>> {
        let parent = self
            .optional_git_text(&["rev-parse", "--verify", "HEAD"])?
            .unwrap_or_default();
        let branch = self.git_text(&["symbolic-ref", "--quiet", "--short", "HEAD"])?;
        if !journal
            .get("source_branch")
            .is_some_and(|recorded| recorded.is_str(&branch))
        {
            return Err(reconciliation(
                format!(
                    "Rollback is on branch {}, not recorded branch {}.",
                    pystr::repr(&branch),
                    value_repr(journal.get("source_branch"))
                ),
                "Return to the recorded source branch or explicitly review a different rollback target.",
                journal,
            ));
        }
        let backup_files = self.backup_bytes()?;
        if parent.is_empty() {
            if get_bool(journal, "source_head_before") {
                return Err(reconciliation(
                    "The recorded source commit is no longer available.",
                    "Restore the recorded source branch before rollback.",
                    journal,
                ));
            }
            for (path, metadata) in get_dict(&get_dict(journal, "manifest"), "files").iter() {
                if !metadata
                    .as_dict()
                    .is_some_and(|meta| get_bool(meta, "tracked"))
                {
                    continue;
                }
                let relative = path.strip_prefix(".orchestrator/").unwrap_or(path);
                let content = backup_files.get(relative).ok_or_else(|| {
                    Error::new(
                        ErrorKind::Runtime,
                        format!("KeyError: {}", pystr::repr(relative)),
                    )
                })?;
                let oid = self.hash_object(content)?;
                self.run_git(
                    &["update-index", "--add", "--cacheinfo", "100644", &oid, path],
                    &[],
                    None,
                    None,
                    &[0],
                )?;
            }
            return Ok(None);
        }
        let temporary = TemporaryDirectory::new("relay-rollback-index-")?;
        let index = path_text(&temporary.path.join("index"));
        let env = [("GIT_INDEX_FILE", index.as_str())];
        self.run_git(&["read-tree", &parent], &env, None, None, &[0])?;
        for (relative, content) in &backup_files {
            let path = format!(".orchestrator/{relative}");
            let oid = self.hash_object(content)?;
            self.run_git(
                &[
                    "update-index",
                    "--add",
                    "--cacheinfo",
                    "100644",
                    &oid,
                    &path,
                ],
                &env,
                None,
                None,
                &[0],
            )?;
        }
        let tree = text_of(
            &self
                .run_git(&["write-tree"], &env, None, None, &[0])?
                .stdout,
        );
        let message = format!(
            "Restore legacy Relay ticket authority\n\n\
             Relay-Migration-Project-ID: {}\n\
             Relay-Migration-Rollback: {}\n\
             Relay-Artifact-Ref-Retained: true\n",
            self.project_id,
            get_str(journal, "manifest_digest")
        );
        let commit = text_of(
            &self
                .run_git(
                    &["commit-tree", &tree, "-p", &parent],
                    &[],
                    Some(message.as_bytes()),
                    None,
                    &[0],
                )?
                .stdout,
        );
        drop(temporary);
        self.run_git(
            &[
                "update-ref",
                &format!("refs/heads/{branch}"),
                &commit,
                &parent,
            ],
            &[],
            None,
            None,
            &[0],
        )?;
        for (relative, content) in &backup_files {
            let path = format!(".orchestrator/{relative}");
            let oid = self.hash_object(content)?;
            self.run_git(
                &[
                    "update-index",
                    "--add",
                    "--cacheinfo",
                    "100644",
                    &oid,
                    &path,
                ],
                &[],
                None,
                None,
                &[0],
            )?;
        }
        Ok(Some(commit))
    }

    fn hash_object(&self, content: &[u8]) -> Result<String> {
        Ok(text_of(
            &self
                .run_git(
                    &["hash-object", "-w", "--stdin"],
                    &[],
                    Some(content),
                    None,
                    &[0],
                )?
                .stdout,
        ))
    }

    fn restore_legacy_materialization(&self) -> Result<()> {
        let target = self.repo.join(".orchestrator");
        let temporary = self
            .repo
            .join(format!(".relay-legacy-rollback-{}", random_hex()));
        self.copy_regular_tree(&self.legacy_backup_path, &temporary)?;
        let seconds = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_secs());
        let displaced = self.migration_root.join(format!(
            "artifact-materialization-before-rollback-{seconds}"
        ));
        if target.exists() || is_symlink(&target) {
            fs::rename(&target, &displaced).map_err(|error| io_error(error, &target))?;
        }
        fs::rename(&temporary, &target).map_err(|error| io_error(error, &temporary))
    }

    fn remove_local_exclude(&self) -> Result<()> {
        let raw = self.git_text(&["rev-parse", "--git-path", "info/exclude"])?;
        let mut path = PathBuf::from(&raw);
        if !path.is_absolute() {
            path = self.repo.join(path);
        }
        let Ok(bytes) = fs::read(&path) else {
            return Ok(());
        };
        let original = pystr::universal_newlines(decode(&bytes)?);
        let lines: Vec<&str> = pystr::splitlines(&original)
            .into_iter()
            .filter(|line| json::py_strip(line) != "/.orchestrator/")
            .collect();
        let mut rendered = lines.join("\n");
        if original.ends_with('\n') && !rendered.is_empty() {
            rendered.push('\n');
        }
        let temporary = beside(&path, &format!(".relay-{}.tmp", random_hex()));
        fs::write(&temporary, rendered).map_err(|error| io_error(error, &temporary))?;
        fs::rename(&temporary, &path).map_err(|error| io_error(error, &path))
    }

    // -- artifact projection and remote verification ---------------------------------

    fn bootstrap_operations(
        &self,
        manifest: &Dict,
        remote_mode: &str,
        remote_name: Option<&str>,
    ) -> Result<(Vec<Operation>, BTreeMap<String, String>)> {
        let source = self.backup_bytes()?;
        let legacy = get_dict(manifest, "legacy_config");
        let next_id = legacy
            .get("next_id")
            .and_then(Value::py_int)
            .ok_or_else(|| Error::value("legacy next_id is not an integer"))?;
        let config = self.artifact_config(
            &get_str(&legacy, "prefix"),
            next_id,
            remote_mode,
            remote_name,
        )?;
        let mut projected = BTreeMap::new();
        projected.insert(".orchestrator/config.toml".to_string(), sha256(&config));
        let mut operations = vec![Operation::ConfigWrite { content: config }];
        let projected_manifest = get_dict(manifest, "projected");
        let mut archive_seen = false;
        for (relative, content) in &source {
            let path = format!(".orchestrator/{relative}");
            let path_parts = parts(&path);
            if path == ".orchestrator/config.toml" {
                continue;
            }
            if path == ".orchestrator/archive-index.jsonl" {
                operations.push(Operation::ArchiveIndexWrite {
                    content: content.clone(),
                });
                projected.insert(path, sha256(content));
                archive_seen = true;
            } else if path_parts.len() == 2 && suffix_of(&path) == ".md" {
                let ticket_id = stem_of(&path).to_string();
                let artifact_id = store::ticket_front_matter_value(content, "artifact_id")
                    .unwrap_or_else(|| artifact_id_for(&self.project_id, &ticket_id));
                let activity = match front_value(content, "activity_at") {
                    Some(activity) => activity,
                    None => get_str(&get_dict(&projected_manifest, &path), "activity_at"),
                };
                let migrated = set_frontmatter_defaults(content, &artifact_id, &activity)?;
                projected.insert(path, sha256(&migrated));
                operations.push(Operation::TicketWrite {
                    ticket_id,
                    artifact_id,
                    markdown: migrated,
                });
            } else if path_parts.len() == 4 && path_parts[..2] == [".orchestrator", "attachments"] {
                let mime_type = store::attachment_mime_for_filename(path_parts[3])?;
                operations.push(Operation::AttachmentWrite {
                    ticket_id: path_parts[2].to_string(),
                    filename: path_parts[3].to_string(),
                    mime_type: mime_type.to_string(),
                    content: content.clone(),
                });
                projected.insert(path, sha256(content));
            } else if path_parts.len() == 4
                && path_parts[..3] == [".orchestrator", "program", "events"]
            {
                let event_id = stem_of(&path).to_string();
                let parsed = store::decode_json_bytes(content)
                    .and_then(|text| json::parse(&text))
                    .ok_or_else(|| Error::value("Expecting value"))?;
                let canonical = json::dumps_compact_sorted_unicode(&parsed) + "\n";
                operations.push(Operation::ProgramEventWrite {
                    event_id,
                    content: content.clone(),
                });
                projected.insert(path, sha256(canonical.as_bytes()));
            }
        }
        if !archive_seen {
            operations.push(Operation::ArchiveIndexWrite {
                content: Vec::new(),
            });
            projected.insert(".orchestrator/archive-index.jsonl".to_string(), sha256(b""));
        }
        Ok((operations, projected))
    }

    fn artifact_config(
        &self,
        prefix: &str,
        next_id: i64,
        remote_mode: &str,
        remote_name: Option<&str>,
    ) -> Result<Vec<u8>> {
        if !["local_only", "enabled"].contains(&remote_mode) {
            return Err(Error::value(format!(
                "invalid migration remote mode: {remote_mode}"
            )));
        }
        if remote_mode == "enabled" && remote_name.is_none_or(str::is_empty) {
            return Err(Error::value(
                "remote-enabled migration requires a selected remote name",
            ));
        }
        if remote_mode == "local_only" && remote_name.is_some() {
            return Err(Error::value(
                "local-only migration cannot name a sync remote",
            ));
        }
        let quote = |text: &str| json::dumps(&Value::Str(text.to_string()));
        let remote_line = remote_name.map_or_else(String::new, |name| {
            format!("remote_name = {}\n", quote(name))
        });
        Ok(format!(
            "schema_version = 2\n\
             project_id = {}\n\
             prefix = {}\n\
             artifact_ref = {}\n\
             remote_sync = {}\n\
             {remote_line}\
             artifact_lifecycle = \"enabled\"\n\
             next_id = {next_id}\n",
            quote(&self.project_id),
            quote(prefix),
            quote(ARTIFACT_REF),
            quote(remote_mode),
        )
        .into_bytes())
    }

    fn inspect_remote_artifact(&self, remote_name: &str) -> Result<BTreeMap<String, Vec<u8>>> {
        let temporary = TemporaryDirectory::new("relay-remote-inspect-")?;
        let git_dir = temporary.path.join("inspect.git");
        let git_dir_flag = format!("--git-dir={}", path_text(&git_dir));
        let plain = |arguments: &[&str], timeout: Option<f64>| -> Result<ProcessOutput> {
            let mut command = Command::new("git");
            command.args(arguments);
            run_process(command, None, timeout)
                .map_err(|error| Error::new(ErrorKind::Io, error.to_string()))?
                .ok_or_else(|| Error::new(ErrorKind::Runtime, "git timed out"))
        };
        let checked = |output: ProcessOutput, arguments: &[&str]| -> Result<ProcessOutput> {
            if output.status != 0 {
                return Err(Error::new(
                    ErrorKind::Runtime,
                    format!(
                        "Command {} returned non-zero exit status {}.",
                        value_repr(Some(&Value::List(
                            arguments
                                .iter()
                                .map(|argument| Value::Str(argument.to_string()))
                                .collect()
                        ))),
                        output.status
                    ),
                ));
            }
            Ok(output)
        };
        let init = ["init", "--bare", "--quiet", &path_text(&git_dir)].map(str::to_string);
        let init: Vec<&str> = init.iter().map(String::as_str).collect();
        checked(plain(&init, None)?, &init)?;
        let url = self.remote_url(remote_name)?;
        let refspec = format!("{ARTIFACT_REF}:refs/heads/inspect");
        let fetch = plain(
            &[&git_dir_flag, "fetch", "--no-tags", &url, &refspec],
            Some(self.remote_timeout_seconds),
        );
        if !fetch.as_ref().is_ok_and(|output| output.status == 0) {
            return Err(blocked(
                "The configured remote artifact ref could not be inspected.",
                "Restore network/auth access or switch to explicit local-only migration.",
            ));
        }
        let listing_arguments = [
            git_dir_flag.as_str(),
            "ls-tree",
            "-r",
            "--name-only",
            "refs/heads/inspect",
        ];
        let listing = checked(plain(&listing_arguments, None)?, &listing_arguments)?;
        let mut files = BTreeMap::new();
        for path in pystr::splitlines(&String::from_utf8_lossy(&listing.stdout)) {
            let spec = format!("refs/heads/inspect:{path}");
            let show = [git_dir_flag.as_str(), "show", spec.as_str()];
            files.insert(
                path.to_string(),
                checked(plain(&show, None)?, &show)?.stdout,
            );
        }
        let config_text = String::from_utf8_lossy(
            files
                .get(".orchestrator/config.toml")
                .map_or(&[][..], Vec::as_slice),
        )
        .into_owned();
        let config = toml::loads(&config_text)?;
        let project = match config.get("project_id") {
            Some(toml::Value::String(text)) => Some(text.clone()),
            _ => None,
        };
        if project.as_deref() != Some(self.project_id.as_str()) {
            let shown = match config.get("project_id") {
                None => "None".to_string(),
                Some(toml::Value::String(text)) => pystr::repr(text),
                Some(toml::Value::Integer(number)) => number.to_string(),
                Some(toml::Value::Boolean(flag)) => {
                    if *flag { "True" } else { "False" }.to_string()
                }
                Some(_) => "<value>".to_string(),
            };
            return Err(blocked(
                format!("Remote artifact ref belongs to project {shown}."),
                "Choose the correct remote/ref or explicitly reconcile the foreign identity.",
            ));
        }
        Ok(files)
    }

    fn push_current_artifact(&self, journal: &Dict, initial: bool) -> Result<Dict> {
        let remote = get_dict(journal, "remote_preflight");
        let name = get_text(&remote, "name");
        if name.is_empty() {
            return Err(blocked_with(
                "Remote publication was requested without a selected remote.",
                "Select a remote or remain local-only.",
                journal,
            ));
        }
        let (fetch_url, push_url) = configured_remote_urls(&self.store, &name)?;
        // Older journals recorded only the fetch URL; they resume when the
        // effective push destination is that same recorded URL.
        let expected_push = remote
            .truthy("push_url_sha256")
            .or_else(|| remote.get("url_sha256"))
            .cloned()
            .unwrap_or(Value::Null);
        if !remote
            .get("url_sha256")
            .is_some_and(|digest| digest.is_str(&sha256(fetch_url.as_bytes())))
            || !expected_push.is_str(&sha256(push_url.as_bytes()))
        {
            return Err(reconciliation(
                "The archive destination changed after migration preflight.",
                "Restore the recorded remote destination before resuming publication.",
                journal,
            ));
        }
        let head = self.store.snapshot()?.commit_id;
        let result = self.run_git(
            &["push", &push_url, &format!("{head}:{ARTIFACT_REF}")],
            &[],
            None,
            Some(self.remote_timeout_seconds),
            &[0, 1, 128],
        )?;
        if result.status != 0 {
            let mut report = Dict::new();
            report.insert("remote", name.as_str());
            report.insert("stderr", bounded_public_error(&result.stderr));
            return Err(blocked_with(
                "Normal artifact push was rejected; no force path was attempted.",
                "Fetch/inspect the remote race or repair auth, then resume safely.",
                &report,
            ));
        }
        let mut pushed = Dict::new();
        pushed.insert("mode", "enabled");
        pushed.insert(
            "state",
            if initial {
                "first_push_verified"
            } else {
                "pushed_current_head"
            },
        );
        pushed.insert("remote", name.as_str());
        pushed.insert("commit", head);
        pushed.insert("force", false);
        pushed.insert("source_ref_published", false);
        Ok(pushed)
    }

    // -- state consistency helpers --------------------------------------------------

    fn validate_resume_identity(
        &self,
        journal: &Dict,
        allow_legacy_materialization: bool,
    ) -> Result<()> {
        let schema_matches = journal
            .get("schema_version")
            .is_some_and(|version| json::py_eq(version, &Value::Int(MIGRATION_SCHEMA_VERSION)));
        let repo_matches = Path::new(&paths::resolve(&get_text(journal, "repo_path"))) == self.repo;
        if !schema_matches
            || !journal
                .get("project_id")
                .is_some_and(|id| id.is_str(&self.project_id))
            || !repo_matches
        {
            return Err(reconciliation(
                "Migration journal identity does not match this project.",
                "Select the recorded project/journal; never transplant migration state.",
                journal,
            ));
        }
        let manifest_ok = match journal.get("manifest") {
            Some(manifest @ Value::Dict(_)) => journal
                .get("manifest_digest")
                .is_some_and(|digest| digest.is_str(&json_digest(manifest))),
            _ => false,
        };
        if !manifest_ok {
            return Err(reconciliation(
                "Migration journal manifest is missing or tampered.",
                "Restore the immutable preflight journal/backup before resuming.",
                journal,
            ));
        }
        let artifact_commit = get_text(journal, "artifact_commit");
        if !artifact_commit.is_empty() {
            let current = self.optional_git_text(&["rev-parse", "--verify", ARTIFACT_REF])?;
            let stage = get_str(journal, "stage");
            if current.as_deref() != Some(artifact_commit.as_str())
                && !(journal
                    .get("stage")
                    .is_some_and(|value| value.as_str().is_some())
                    && RESUMABLE_STAGES.contains(&stage.as_str()))
            {
                return Err(reconciliation(
                    format!(
                        "Artifact ref changed during migration: expected {artifact_commit}, found {}.",
                        current.as_deref().unwrap_or("None")
                    ),
                    "Reconcile immutable event IDs before resuming.",
                    journal,
                ));
            }
        }
        if !allow_legacy_materialization
            && (get_bool(journal, "source_cutover_complete") || get_bool(journal, "source_commit"))
        {
            let current_source = self
                .optional_git_text(&["rev-parse", "--verify", "HEAD"])?
                .unwrap_or_default();
            if !journal
                .get("source_commit")
                .is_some_and(|commit| commit.is_str(&current_source))
            {
                return Err(reconciliation(
                    "Source HEAD changed after migration cutover.",
                    "Review the new source history before resuming or rolling back.",
                    journal,
                ));
            }
        }
        Ok(())
    }

    /// `_revalidate_unrelated_source` before cutover, and
    /// `_verify_unrelated_source_after_cutover` after it.
    fn revalidate_unrelated_source(&self, journal: &Dict, after_cutover: bool) -> Result<()> {
        let before = get_dict(journal, "git_before");
        let head = self
            .optional_git_text(&["rev-parse", "--verify", "HEAD"])?
            .unwrap_or_default();
        let current = self.git_state(&get_str(journal, "source_branch"), &head)?;
        for field in [
            "unrelated_index_sha256",
            "unrelated_status_sha256",
            "remotes_sha256",
        ] {
            if !json::py_eq_optional(current.get(field), before.get(field)) {
                return Err(if after_cutover {
                    reconciliation(
                        format!("Source cleanup changed unrelated state ({field})."),
                        "Stop before further writes and restore/reconcile using the journal.",
                        journal,
                    )
                } else {
                    reconciliation(
                        format!("Unrelated source state changed after preflight ({field})."),
                        "Review the unrelated source/index/remote change and restart with a fresh preflight.",
                        journal,
                    )
                });
            }
        }
        Ok(())
    }

    fn git_state(&self, source_branch: &str, source_head: &str) -> Result<Dict> {
        let status = self
            .run_git(
                &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                &[],
                None,
                None,
                &[0],
            )?
            .stdout;
        let unrelated_status = join_nul(
            status
                .split(|byte| *byte == 0)
                .filter(|record| !record.is_empty() && !contains(record, b".orchestrator")),
        );
        let index = self
            .run_git(&["ls-files", "--stage", "-z"], &[], None, None, &[0])?
            .stdout;
        let unrelated_index = join_nul(
            index
                .split(|byte| *byte == 0)
                .filter(|record| !record.is_empty() && !contains(record, b"\t.orchestrator/")),
        );
        let refs = Value::List(self.ref_records()?.into_iter().map(Value::Dict).collect());
        let remotes = Value::List(
            self.remote_records()?
                .into_iter()
                .map(Value::Dict)
                .collect(),
        );
        let mut result = Dict::new();
        result.insert("source_branch", source_branch);
        result.insert("source_head", source_head);
        result.insert("status_sha256", sha256(&status));
        result.insert("unrelated_status_sha256", sha256(&unrelated_status));
        result.insert("index_sha256", sha256(&index));
        result.insert("unrelated_index_sha256", sha256(&unrelated_index));
        result.insert("refs_sha256", json_digest(&refs));
        result.insert("refs", refs);
        result.insert("remotes_sha256", json_digest(&remotes));
        result.insert("remotes", remotes);
        Ok(result)
    }

    fn tracked_orchestrator_entries(&self) -> Result<Vec<(String, String)>> {
        let raw = self
            .run_git(
                &["ls-files", "--stage", "-z", "--", ".orchestrator"],
                &[],
                None,
                None,
                &[0],
            )?
            .stdout;
        let mut result: Vec<(String, String)> = Vec::new();
        for record in raw
            .split(|byte| *byte == 0)
            .filter(|record| !record.is_empty())
        {
            let Some(tab) = record.iter().position(|byte| *byte == b'\t') else {
                continue;
            };
            let metadata = String::from_utf8_lossy(&record[..tab]);
            let path = String::from_utf8_lossy(&record[tab + 1..]).into_owned();
            let mode = metadata
                .split_whitespace()
                .next()
                .unwrap_or_default()
                .to_string();
            match result.iter_mut().find(|(existing, _)| *existing == path) {
                Some(entry) => entry.1 = mode,
                None => result.push((path, mode)),
            }
        }
        Ok(result)
    }

    fn ref_records(&self) -> Result<Vec<Dict>> {
        let output = self.run_git(
            &[
                "for-each-ref",
                "--format=%(refname)%00%(objectname)",
                "refs/heads",
                "refs/remotes",
            ],
            &[],
            None,
            None,
            &[0],
        )?;
        let text = String::from_utf8_lossy(&output.stdout).into_owned();
        let mut records = Vec::new();
        for line in pystr::splitlines(&text) {
            let (reference, found, oid) = pystr::partition(line, "\0");
            if found {
                let mut record = Dict::new();
                record.insert("ref", reference);
                record.insert("oid", oid);
                records.push(record);
            }
        }
        Ok(records)
    }

    fn remote_records(&self) -> Result<Vec<Dict>> {
        let mut names: Vec<String> = pystr::splitlines(&self.git_text(&["remote"])?)
            .into_iter()
            .filter(|name| !name.is_empty())
            .map(str::to_string)
            .collect();
        names.sort();
        let mut result = Vec::new();
        for name in names {
            let url = self.git_text(&["remote", "get-url", &name])?;
            let mut record = Dict::new();
            record.insert("name", name.as_str());
            record.insert("locator", safe_remote_locator(&url)?);
            record.insert("url_sha256", sha256(url.as_bytes()));
            result.push(record);
        }
        Ok(result)
    }

    fn remote_url(&self, remote_name: &str) -> Result<String> {
        self.git_text(&["remote", "get-url", remote_name])
    }

    fn default_branch(&self, source_branch: &str) -> Result<String> {
        for remote in pystr::splitlines(&self.git_text(&["remote"])?) {
            let candidate = self.optional_git_text(&[
                "symbolic-ref",
                "--quiet",
                "--short",
                &format!("refs/remotes/{remote}/HEAD"),
            ])?;
            if let Some(candidate) = candidate
                && let Some((_, branch)) = candidate.split_once('/')
            {
                return Ok(branch.to_string());
            }
        }
        Ok(source_branch.to_string())
    }

    fn write_registry_mode(&self, mode: &str, remote_name: Option<&Value>) -> Result<()> {
        let bytes =
            fs::read(&self.registry_path).map_err(|error| io_error(error, &self.registry_path))?;
        let mut document = match json::parse(&pystr::universal_newlines(decode(&bytes)?)) {
            Some(Value::Dict(dict)) => dict,
            _ => return Err(Error::value("Expecting value")),
        };
        let selected = if mode == "enabled" {
            remote_name.cloned().unwrap_or(Value::Null)
        } else {
            Value::Null
        };
        let mut matches = 0;
        let mut projects = document
            .get("projects")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .to_vec();
        for entry in &mut projects {
            let Value::Dict(record) = entry else {
                continue;
            };
            if !record
                .get("project_id")
                .is_some_and(|id| id.is_str(&self.project_id))
            {
                continue;
            }
            matches += 1;
            let mut remote = get_dict(record, "remote");
            remote.insert("mode", mode);
            if remote.get("artifactRef").is_some() {
                remote.insert("artifactRef", ARTIFACT_REF);
                remote.insert("remoteName", selected.clone());
            } else {
                remote.insert("artifact_ref", ARTIFACT_REF);
                remote.insert("remote_name", selected.clone());
            }
            record.insert("remote", remote);
            record.insert("updated_at", now_iso());
        }
        if matches != 1 {
            return Err(blocked(
                "Registry identity changed after preflight.",
                "Restore the registry backup and rerun preflight.",
            ));
        }
        if document.get("projects").is_some() {
            document.insert("projects", Value::List(projects));
        }
        write_json(&self.registry_path, &document)
    }

    fn restore_registry_backup(&self) -> Result<()> {
        if !self.registry_backup_path.exists() {
            return Ok(());
        }
        let temporary = beside(&self.registry_path, &format!(".{}.tmp", random_hex()));
        if let Some(parent) = temporary.parent() {
            fs::create_dir_all(parent).map_err(|error| io_error(error, parent))?;
        }
        let bytes = fs::read(&self.registry_backup_path)
            .map_err(|error| io_error(error, &self.registry_backup_path))?;
        fs::write(&temporary, bytes).map_err(|error| io_error(error, &temporary))?;
        chmod(&temporary, 0o600)?;
        fs::rename(&temporary, &self.registry_path)
            .map_err(|error| io_error(error, &self.registry_path))
    }

    // -- files, journal and process helpers ---------------------------------------

    fn backup_bytes(&self) -> Result<BTreeMap<String, Vec<u8>>> {
        if !is_dir(&self.legacy_backup_path) {
            return Err(blocked(
                "Legacy backup is unavailable.",
                "Restore the exact backup recorded by the journal.",
            ));
        }
        let mut result = BTreeMap::new();
        for (relative, path) in regular_files(&self.legacy_backup_path) {
            let content = fs::read(&path).map_err(|error| io_error(error, &path))?;
            result.insert(relative, content);
        }
        Ok(result)
    }

    fn copy_regular_tree(&self, source: &Path, destination: &Path) -> Result<()> {
        if destination.exists() || is_symlink(destination) {
            return Err(blocked(
                format!(
                    "Migration temporary path already exists: {}",
                    path_text(destination)
                ),
                "Review and remove only that recorded temporary path before resuming.",
            ));
        }
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(|error| io_error(error, parent))?;
        }
        fs::DirBuilder::new()
            .mode(0o700)
            .create(destination)
            .map_err(|error| io_error(error, destination))?;
        for (directory, directories, filenames) in walk(source)? {
            let relative = directory.strip_prefix(source).unwrap_or(Path::new(""));
            let target_directory = destination.join(relative);
            fs::create_dir_all(&target_directory)
                .map_err(|error| io_error(error, &target_directory))?;
            for name in &directories {
                if is_symlink(&directory.join(name)) {
                    return Err(blocked(
                        "Backup refused a symlinked legacy directory.",
                        "Repair the legacy tree and restart preflight.",
                    ));
                }
            }
            for name in &filenames {
                let path = directory.join(name);
                if is_symlink(&path) || !is_file(&path) {
                    return Err(blocked(
                        "Backup refused a non-regular legacy file.",
                        "Repair the legacy tree and restart preflight.",
                    ));
                }
                let target = target_directory.join(name);
                let content = fs::read(&path).map_err(|error| io_error(error, &path))?;
                fs::write(&target, content).map_err(|error| io_error(error, &target))?;
                chmod(&target, 0o600)?;
            }
        }
        Ok(())
    }

    fn directory_manifest(&self, root: &Path, prefix: &str) -> Dict {
        let journal = self.load_journal();
        let recorded = get_dict(&get_dict(&journal, "manifest"), "files");
        let mut result = Dict::new();
        for (relative, path) in regular_files(root) {
            let Ok(content) = fs::read(&path) else {
                continue;
            };
            let key = format!("{prefix}/{relative}");
            let original = get_dict(&recorded, &key);
            let mut entry = Dict::new();
            entry.insert("sha256", sha256(&content));
            entry.insert("bytes", content.len() as i64);
            entry.insert(
                "mtime_ns",
                original.get("mtime_ns").cloned().unwrap_or(Value::Int(0)),
            );
            entry.insert(
                "tracked",
                original
                    .get("tracked")
                    .cloned()
                    .unwrap_or(Value::Bool(false)),
            );
            result.insert(&key, entry);
        }
        result
    }

    fn load_journal(&self) -> Dict {
        read_json_object(&self.journal_path)
    }

    fn write_journal(&self, journal: &Dict) -> Result<()> {
        write_json(&self.journal_path, journal)
    }

    fn result_from_journal(&self, journal: &Dict, idempotent: bool) -> Result<MigrationResult> {
        let required = |key: &str| -> Result<String> {
            journal.get(key).map(Value::py_str).ok_or_else(|| {
                Error::new(
                    ErrorKind::Runtime,
                    format!("KeyError: {}", pystr::repr(key)),
                )
            })
        };
        Ok(MigrationResult {
            project_id: self.project_id.clone(),
            stage: required("stage")?,
            artifact_commit: required("artifact_commit")?,
            source_commit: journal.truthy("source_commit").map(Value::py_str),
            manifest_digest: required("manifest_digest")?,
            remote_result: get_dict(journal, "remote_result"),
            retention_preview: get_dict(journal, "retention_preview"),
            journal_path: path_text(&self.journal_path),
            idempotent,
        })
    }

    fn rollback_instructions(&self, journal: &Dict) -> Dict {
        let mut result = Dict::new();
        result.insert("journal", path_text(&self.journal_path));
        result.insert("legacy_backup", path_text(&self.legacy_backup_path));
        result.insert("registry_backup", path_text(&self.registry_backup_path));
        result.insert(
            "source_commit",
            journal.get("source_commit").cloned().unwrap_or(Value::Null),
        );
        result.insert(
            "artifact_commit",
            journal
                .get("artifact_commit")
                .cloned()
                .unwrap_or(Value::Null),
        );
        result.insert("artifact_ref_retained", true);
        result.insert("remote_ref_retained", true);
        result.insert(
            "command",
            format!(
                "relay-artifact-migrate rollback --repo {} --project-id {}",
                path_text(&self.repo),
                self.project_id
            ),
        );
        result.insert(
            "event_reconciliation",
            "Required if artifact head or legacy materialization advanced after cutover.",
        );
        result
    }

    fn inject(&self, stage: &str) -> Result<()> {
        let Some(injector) = &self.failure_injector else {
            return Ok(());
        };
        match injector(stage) {
            Ok(()) => Ok(()),
            Err(error) if error.kind == ErrorKind::MigrationInjectedFailure => Err(error),
            Err(error) => {
                let mut report = Dict::new();
                report.insert("stage", stage);
                Err(migration_error(
                    ErrorKind::MigrationInjectedFailure,
                    format!(
                        "Injected migration interruption at {stage}: {}",
                        error.message
                    ),
                    "Resume with the same journal; do not delete refs or backups.",
                    report,
                ))
            }
        }
    }

    fn absolute_git_path(&self, raw: &str) -> String {
        let path = Path::new(raw);
        let path = if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.repo.join(path)
        };
        paths::resolve(&path_text(&path))
    }

    /// `_run_git`: `git -C <repo>` with the migration's environment.
    fn run_git(
        &self,
        arguments: &[&str],
        additions: &[(&str, &str)],
        input: Option<&[u8]>,
        timeout: Option<f64>,
        allowed: &[i32],
    ) -> Result<ProcessOutput> {
        let mut environment: Vec<(&str, &str)> = vec![("GIT_OPTIONAL_LOCKS", "0")];
        environment.extend_from_slice(additions);
        let mut command = Command::new("git");
        command
            .arg("-C")
            .arg(&self.repo)
            .args(arguments)
            .env_clear()
            .envs(crate::git::environment(&environment));
        let output = run_process(command, input, timeout)
            .map_err(|error| Error::new(ErrorKind::Io, error.to_string()))?
            .ok_or_else(|| {
                blocked(
                    format!("Git {} timed out.", arguments.join(" ")),
                    "Restore responsive local/remote access, then rerun preflight.",
                )
            })?;
        if !allowed.contains(&output.status) {
            return Err(blocked(
                format!(
                    "Git {} failed: {}",
                    arguments.join(" "),
                    bounded_public_error(&output.stderr)
                ),
                "Repair the exact Git condition and rerun the journaled step.",
            ));
        }
        Ok(output)
    }

    fn git_text(&self, arguments: &[&str]) -> Result<String> {
        Ok(text_of(
            &self.run_git(arguments, &[], None, None, &[0])?.stdout,
        ))
    }

    fn optional_git_text(&self, arguments: &[&str]) -> Result<Option<String>> {
        let output = self.run_git(arguments, &[], None, None, &[0, 1, 128])?;
        if output.status != 0 {
            return Ok(None);
        }
        let value = text_of(&output.stdout);
        Ok((!value.is_empty()).then_some(value))
    }
}

fn legacy_config_blocked() -> Error {
    blocked(
        "Legacy config requires an alphanumeric prefix and positive integer next_id.",
        "Repair config.toml using the last verified ticket allocation state.",
    )
}

fn block(blockers: &mut Vec<Dict>, kind: &str, detail: &str, recovery: &str) {
    let mut blocker = Dict::new();
    blocker.insert("kind", kind);
    blocker.insert("detail", detail);
    blocker.insert("recovery", recovery);
    blockers.push(blocker);
}

/// `_validate_legacy_path`.
fn validate_legacy_path(relative: &str) -> Result<()> {
    let path_parts = parts(relative);
    let allowed = relative == ".orchestrator/config.toml"
        || relative == ".orchestrator/archive-index.jsonl"
        || (path_parts.len() == 2
            && path_parts[0] == ".orchestrator"
            && suffix_of(relative) == ".md")
        || (path_parts.len() == 4 && path_parts[..2] == [".orchestrator", "attachments"])
        || (path_parts.len() == 4
            && path_parts[..3] == [".orchestrator", "program", "events"]
            && suffix_of(relative) == ".json");
    if allowed {
        Ok(())
    } else {
        Err(blocked(
            format!("Legacy path is outside the artifact allowlist: {relative}"),
            "Classify and relocate the file before migration; do not silently drop it.",
        ))
    }
}

/// `_attachment_references`: `attachments/...` link targets under the
/// ticket's `## Attachments` heading.
fn attachment_references(body: &str) -> Vec<String> {
    let mut inside = false;
    let mut found: Vec<String> = Vec::new();
    for line in pystr::splitlines(body) {
        let stripped = json::py_strip(line);
        let lower = stripped.to_lowercase();
        if lower == "## attachments" || lower.starts_with("## attachments ") {
            inside = true;
            continue;
        }
        if inside && stripped.starts_with('#') {
            break;
        }
        if !inside {
            continue;
        }
        let Some(start) = stripped.find("](") else {
            continue;
        };
        let Some(end) = stripped[start + 2..]
            .find(')')
            .map(|offset| start + 2 + offset)
        else {
            continue;
        };
        let destination = &stripped[start + 2..end];
        if destination.starts_with("attachments/") && !found.iter().any(|item| item == destination)
        {
            found.push(destination.to_string());
        }
    }
    found
}

/// `_verify_projected_hashes`.
fn verify_projected_hashes(
    files: &BTreeMap<String, Vec<u8>>,
    expected: &BTreeMap<String, String>,
) -> Result<()> {
    let actual: BTreeMap<&String, String> = files
        .iter()
        .map(|(path, content)| (path, sha256(content)))
        .collect();
    let same = actual.len() == expected.len()
        && actual
            .iter()
            .all(|(path, digest)| expected.get(*path) == Some(digest));
    if same {
        return Ok(());
    }
    let missing: Vec<String> = expected
        .keys()
        .filter(|path| !actual.contains_key(path))
        .cloned()
        .collect();
    let extra: Vec<String> = actual
        .keys()
        .filter(|path| !expected.contains_key(**path))
        .map(|path| path.to_string())
        .collect();
    let changed: Vec<String> = actual
        .iter()
        .filter(|(path, digest)| expected.get(**path).is_some_and(|wanted| wanted != *digest))
        .map(|(path, _)| path.to_string())
        .collect();
    let mut report = Dict::new();
    report.insert("missing", strings(&missing));
    report.insert("extra", strings(&extra));
    report.insert("changed", strings(&changed));
    Err(blocked_with(
        "Artifact bootstrap failed byte-level round-trip verification.",
        "Stop before source cleanup and review missing/extra/changed manifest paths.",
        &report,
    ))
}

fn nul_list(paths: &[String]) -> Vec<u8> {
    let mut bytes = paths
        .iter()
        .map(|path| path.as_bytes())
        .collect::<Vec<_>>()
        .join(&0u8);
    bytes.push(0);
    bytes
}

fn join_nul<'r>(records: impl Iterator<Item = &'r [u8]>) -> Vec<u8> {
    records.collect::<Vec<_>>().join(&0u8)
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

fn remove_if_present(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(io_error(error, path)),
        _ => Ok(()),
    }
}

fn open_read_only(path: &Path) -> rusqlite::Result<rusqlite::Connection> {
    rusqlite::Connection::open_with_flags(
        format!("file:{}?mode=ro", path_text(path)),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
    )
}

fn sqlite_message(message: &str) -> rusqlite::Error {
    rusqlite::Error::SqliteFailure(
        rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_ERROR),
        Some(message.to_string()),
    )
}

/// `str(sqlite3.Error)`: SQLite's own message.
fn sqlite_text(error: &rusqlite::Error) -> String {
    match error {
        rusqlite::Error::SqliteFailure(_, Some(message)) => message.clone(),
        rusqlite::Error::SqliteFailure(code, None) => code.to_string(),
        other => other.to_string(),
    }
}

fn sqlite_value(value: rusqlite::types::ValueRef<'_>) -> Value {
    use rusqlite::types::ValueRef;
    match value {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(number) => Value::Int(number),
        ValueRef::Real(number) => Value::Float(number),
        ValueRef::Text(text) => Value::Str(String::from_utf8_lossy(text).into_owned()),
        ValueRef::Blob(bytes) => Value::Str(String::from_utf8_lossy(bytes).into_owned()),
    }
}

/// `tempfile.TemporaryDirectory(prefix=...)`: removed when dropped.
struct TemporaryDirectory {
    path: PathBuf,
}

impl TemporaryDirectory {
    fn new(prefix: &str) -> Result<Self> {
        let base = std::env::var_os("TMPDIR").map_or_else(std::env::temp_dir, PathBuf::from);
        let path = base.join(format!("{prefix}{}", &random_hex()[..8]));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .map_err(|error| io_error(error, &path))?;
        Ok(Self { path })
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

// -- the command line ------------------------------------------------------------------

const USAGE: &str = "usage: artifact_migration_cli.py [-h] --repo REPO --project-id PROJECT_ID [--state-root STATE_ROOT] [--registry REGISTRY] [--runs-db RUNS_DB] [--graphify-db GRAPHIFY_DB] [--confirm-source-cleanup] [--confirm-first-push] [--provider {codex,claude}] {preview,migrate,rollback}";

fn usage_error(message: &str) -> u8 {
    eprintln!("{USAGE}");
    eprintln!("artifact_migration_cli.py: error: {message}");
    2
}

/// `artifact_migration_cli.main()`: returns the exit status.
pub fn cli_main(arguments: &[String]) -> u8 {
    if arguments
        .iter()
        .any(|argument| argument == "-h" || argument == "--help")
    {
        println!(
            "{USAGE}\n\nGuarded RR-270 phase-8 migration; preview is read-only and execution is journaled."
        );
        return 0;
    }
    let valued = [
        "--repo",
        "--project-id",
        "--state-root",
        "--registry",
        "--runs-db",
        "--graphify-db",
        "--provider",
    ];
    let flags = ["--confirm-source-cleanup", "--confirm-first-push"];
    let mut positional = Vec::new();
    let mut options: Vec<String> = Vec::new();
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        if argument.starts_with("--") {
            options.push(argument.clone());
            let name = argument.split('=').next().unwrap_or_default();
            let takes_value = !argument.contains('=')
                && valued
                    .iter()
                    .filter(|option| option.starts_with(name))
                    .count()
                    == 1
                && !flags.iter().any(|flag| flag.starts_with(name));
            if takes_value && index + 1 < arguments.len() {
                index += 1;
                options.push(arguments[index].clone());
            }
        } else {
            positional.push(argument.clone());
        }
        index += 1;
    }
    let Some(action) = positional.first().cloned() else {
        return usage_error("the following arguments are required: action, --repo, --project-id");
    };
    if positional.len() > 1 {
        return usage_error(&format!(
            "unrecognized arguments: {}",
            positional[1..].join(" ")
        ));
    }
    if !["preview", "migrate", "rollback"].contains(&action.as_str()) {
        return usage_error(&format!(
            "argument action: invalid choice: {} (choose from preview, migrate, rollback)",
            pystr::repr(&action)
        ));
    }
    let parsed = match crate::rollout::parse_options(&options, &valued, &flags, false) {
        Ok((parsed, _)) => parsed,
        Err(message) => return usage_error(&message),
    };
    let missing: Vec<&str> = ["--repo", "--project-id"]
        .into_iter()
        .filter(|name| parsed.value(name).is_none())
        .collect();
    if !missing.is_empty() {
        return usage_error(&format!(
            "the following arguments are required: {}",
            missing.join(", ")
        ));
    }
    if let Some(provider) = parsed.value("--provider")
        && !["codex", "claude"].contains(&provider)
    {
        return usage_error(&format!(
            "argument --provider: invalid choice: {} (choose from codex, claude)",
            pystr::repr(provider)
        ));
    }
    let outcome = (|| -> Result<Value> {
        let state_text = parsed.value("--state-root").map_or_else(
            || {
                let home = std::env::var("HOME").unwrap_or_default();
                format!("{home}/Library/Application Support/relay-runner")
            },
            str::to_string,
        );
        let state = resolve_user(&state_text)?;
        let optional = |name: &str, default: &str| -> PathBuf {
            parsed
                .value(name)
                .map_or_else(|| state.join(default), PathBuf::from)
        };
        let coordinator = ArtifactMigrationCoordinator::new(
            Path::new(parsed.value("--repo").unwrap_or_default()),
            parsed.value("--project-id").unwrap_or_default(),
            &state,
            &optional("--registry", "projects/registry-v2.json"),
            MigrationOptions {
                runs_db_path: Some(optional("--runs-db", "orchestrator/runs.db")),
                graphify_path: Some(optional("--graphify-db", "orchestrator/graphify.db")),
                device_id: "migration-cli".to_string(),
                provider: parsed.value("--provider").map(str::to_string),
                ..MigrationOptions::default()
            },
        )?;
        Ok(Value::Dict(match action.as_str() {
            "preview" => coordinator.preview()?.as_dict(),
            "migrate" => coordinator
                .migrate(
                    parsed.flag("--confirm-source-cleanup"),
                    parsed.flag("--confirm-first-push"),
                )?
                .as_dict(),
            _ => coordinator.rollback()?.as_dict(),
        }))
    })();
    match outcome {
        Ok(result) => {
            let mut answer = Dict::new();
            answer.insert("ok", true);
            answer.insert("result", result);
            println!("{}", dumps_indent_sorted(&Value::Dict(answer)));
            0
        }
        Err(error) if error.kind.is_migration() => {
            let mut answer = Dict::new();
            answer.insert("ok", false);
            answer.insert("error", error.message.as_str());
            answer.insert("recovery", error.recovery.clone());
            answer.insert(
                "report",
                error
                    .report
                    .clone()
                    .unwrap_or_else(|| Value::Dict(Dict::new())),
            );
            println!("{}", dumps_indent_sorted(&Value::Dict(answer)));
            2
        }
        Err(error) => {
            eprintln!("{}: {}", error.kind.python_class(), error.message);
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locators_drop_credentials_query_and_fragment() {
        assert_eq!(
            safe_remote_locator("https://user:secret@GitHub.com/o/r.git?x=1#f").unwrap(),
            "https://github.com/o/r.git"
        );
        assert_eq!(
            safe_remote_locator("git@github.com:o/r.git").unwrap(),
            "ssh://github.com:o/r.git"
        );
        assert_eq!(
            safe_remote_locator("file:///tmp/r.git").unwrap(),
            "file:///tmp/r.git"
        );
        assert_eq!(
            safe_remote_locator("ssh://git@host:2222/r").unwrap(),
            "ssh://host:2222/r"
        );
        assert_eq!(
            safe_remote_locator("/tmp//r/").unwrap(),
            "local-path:/tmp/r"
        );
    }

    #[test]
    fn public_errors_drop_http_credentials() {
        assert_eq!(
            bounded_public_error(b"fatal: https://user:tok@github.com/x failed\n"),
            "fatal: https://github.com/x failed"
        );
        assert_eq!(bounded_public_error(b"  "), "unknown Git error");
    }

    #[test]
    fn legacy_content_gains_the_cancellation_flag() {
        let content = b"---\nid: CT-1\ntitle: x\n---\n\nbody\n";
        assert_eq!(
            legacy_ticket_content(content).unwrap(),
            b"---\nid: CT-1\ntitle: x\ncanceled: false\n---\n\nbody\n"
        );
        let migrated =
            set_frontmatter_defaults(content, "ticket-a", "2026-01-01T00:00:00Z").unwrap();
        assert_eq!(
            String::from_utf8(migrated).unwrap(),
            "---\nid: CT-1\nartifact_id: ticket-a\nactivity_at: 2026-01-01T00:00:00Z\ntitle: x\ncanceled: false\n---\n\nbody\n"
        );
    }

    #[test]
    fn mtimes_round_half_even_to_microseconds() {
        assert_eq!(
            mtime_iso(1_780_000_000_123_456_789),
            "2026-05-28T20:26:40.123457Z"
        );
        assert_eq!(mtime_iso(0), "1970-01-01T00:00:00.000000Z");
    }

    #[test]
    fn attachment_references_read_only_the_attachments_section() {
        let body = "## Description\n[x](attachments/CT-1/a.png)\n## Attachments\n- [a](attachments/CT-1/a.png)\n- [a](attachments/CT-1/a.png)\n# Next\n[b](attachments/CT-1/b.png)\n";
        assert_eq!(attachment_references(body), vec!["attachments/CT-1/a.png"]);
    }
}
