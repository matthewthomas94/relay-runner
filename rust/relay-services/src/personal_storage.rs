//! `services/personal_file_storage.py`: optional, account-bound personal
//! files with a verified, bounded local cache.
//!
//! GitHub is reached through `gh` and its credential store; no Git checkout
//! or access token is kept here. Each uploaded version has an immutable
//! commit, Git blob and SHA-256 proof, and publication never force-updates a
//! ref. Operational app files are outside the explicit user-file allowlist.
//!
//! The catalog is `<state root>/personal-storage/catalog.sqlite3`, opened
//! with the Python schema (`relay_store::personal_catalog`) and written with
//! the Python statements and JSON, inside the same implicit transactions
//! Python's `sqlite3` module opens, so a Rust and a Python daemon read each
//! other's catalog and cache. A refusal is a `StorageError` whose
//! [`Error::state`] is the storage state the route reports with a 409.

use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, Weak};
use std::thread::{self, ThreadId};
use std::time::{Duration, Instant};

use relay_artifacts::paths;
use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256;
use relay_store::personal_catalog::SCHEMA;
use relay_store::sql::sql_to_json;
use rusqlite::Connection;
use rusqlite::types::Value as Sql;

use crate::notes::global::GlobalNoteLibrary;
use crate::notes::personal::PersonalNoteManager;
use crate::notes::util::{self, b64decode_strict, b64encode, git_blob_id};
use crate::{Error, Result};

pub const DEFAULT_BUDGET_BYTES: i64 = 256 * 1024 * 1024;
pub const DEFAULT_RETENTION_DAYS: i64 = 30;
pub const MARKER_PATH: &str = ".relay-runner-storage.json";
pub const CATALOG_PATH: &str = "relay-catalog.json";
pub const REPO_DESCRIPTION: &str = "Private personal notes and task files for Relay Runner";
const DISCLOSURE: &str = "Only approved personal notes, task artifacts and documents are uploaded. The private repository is accessible to your GitHub account and anyone you grant access. Provider credentials, terminal logs, operational databases and project boards are excluded.";

/// `StorageError(state, message)`.
pub fn storage_error(state: &str, message: impl Into<String>) -> Error {
    Error {
        class: "StorageError",
        message: message.into(),
        state: Some(state.to_string()),
    }
}

fn state_of(error: &Error) -> Option<&str> {
    (error.class == "StorageError")
        .then_some(error.state.as_deref())
        .flatten()
}

fn key_error(key: &str) -> Error {
    Error::new("KeyError", json::str_repr(key))
}

/// `value[key]` on a JSON object.
fn field<'v>(value: &'v Value, key: &str) -> Result<&'v Value> {
    match value {
        Value::Dict(dict) => dict.get(key).ok_or_else(|| key_error(key)),
        _ => Err(Error::new(
            "TypeError",
            "list indices must be integers or slices, not str",
        )),
    }
}

fn field_str(value: &Value, key: &str) -> Result<String> {
    Ok(field(value, key)?.py_str())
}

fn is_id(text: &str) -> bool {
    (1..=160).contains(&text.len())
        && text
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':' | '-'))
}

fn is_repo_name(text: &str) -> bool {
    (1..=100).contains(&text.len())
        && text
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
}

fn is_hex(text: &str, length: usize) -> bool {
    text.len() == length && text.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f'))
}

/// `urllib.parse.quote(text, safe="")`.
fn quote(text: &str) -> String {
    text.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'_' | b'.' | b'-' | b'~' => {
                (byte as char).to_string()
            }
            other => format!("%{other:02X}"),
        })
        .collect()
}

/// `PurePosixPath(path).suffix`.
fn suffix(path: &str) -> String {
    let name = path.rsplit('/').find(|part| !part.is_empty()).unwrap_or("");
    match name.rfind('.') {
        Some(index) if index > 0 && index < name.len() - 1 => name[index..].to_string(),
        _ => String::new(),
    }
}

fn is_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink())
}

fn is_file(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|metadata| metadata.is_file())
}

fn resolve(path: &Path) -> PathBuf {
    PathBuf::from(paths::resolve(&path.to_string_lossy()))
}

fn relative(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .map(|relative| relative.to_string_lossy().into_owned())
        .unwrap_or_else(|_| path.to_string_lossy().into_owned())
}

fn fsync(file: &File) -> std::io::Result<()> {
    // SAFETY: the descriptor belongs to `file`, which outlives the call.
    if unsafe { libc::fsync(file.as_raw_fd()) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

/// Writes `content` to a new owner-only file next to `path`, synced; returns
/// the temporary path.
fn write_temporary(path: &Path, content: &[u8]) -> Result<PathBuf> {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let temporary = path.with_file_name(format!("{name}.tmp-{}", util::uuid4_hex()));
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o666)
        .open(&temporary)?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    output.write_all(content)?;
    output.flush()?;
    fsync(&output)?;
    Ok(temporary)
}

/// `os.walk(top, followlinks=False)`, top-down, with `visit` free to prune
/// the directory names. Unreadable directories are skipped, as `os.walk`
/// skips them without an `onerror`.
type Visit<'v> = dyn FnMut(&Path, &mut Vec<String>, &[String]) -> Result<()> + 'v;

fn walk(top: &Path, visit: &mut Visit<'_>) -> Result<()> {
    let Ok(entries) = fs::read_dir(top) else {
        return Ok(());
    };
    let mut dirs = Vec::new();
    let mut files = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if fs::metadata(entry.path()).is_ok_and(|metadata| metadata.is_dir()) {
            dirs.push(name);
        } else {
            files.push(name);
        }
    }
    dirs.sort();
    files.sort();
    visit(top, &mut dirs, &files)?;
    for name in dirs {
        let path = top.join(&name);
        if !is_symlink(&path) {
            walk(&path, visit)?;
        }
    }
    Ok(())
}

/// The finished `gh` command: status, stdout and stderr.
pub struct CommandOutput {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// `subprocess.run(command, input=..., capture_output=True, timeout=...)`:
/// `Ok(None)` on a timeout, after killing the process.
fn run_command(
    command: &mut Command,
    input: Option<&[u8]>,
    timeout: Duration,
) -> std::io::Result<Option<CommandOutput>> {
    let mut child = command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
        let input = input.to_vec();
        thread::spawn(move || {
            let _ = stdin.write_all(&input);
        });
    }
    let read = |mut source: Box<dyn Read + Send>| {
        thread::spawn(move || {
            let mut buffer = Vec::new();
            let _ = source.read_to_end(&mut buffer);
            buffer
        })
    };
    let stdout = read(Box::new(child.stdout.take().expect("piped stdout")));
    let stderr = read(Box::new(child.stderr.take().expect("piped stderr")));
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(Some(CommandOutput {
                status: status.code().unwrap_or(-1),
                stdout: stdout.join().unwrap_or_default(),
                stderr: stderr.join().unwrap_or_default(),
            }));
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Ok(None);
        }
        thread::sleep(Duration::from_millis(10));
    }
}

/// The GitHub REST transport `GitHubFiles.api` uses. Tests replace it.
pub trait GitHubApi: Send + Sync {
    /// The `gh` executable, when installed.
    fn executable(&self) -> Option<PathBuf>;
    /// One REST call; `body` is sent as JSON.
    fn api(&self, method: &str, endpoint: &str, body: Option<&Value>) -> Result<Value>;
}

/// `GitHubFiles.api` over the GitHub CLI: credentials stay with gh and the
/// Keychain, and gh's diagnostics never surface.
pub struct GhCli {
    pub executable: Option<PathBuf>,
}

impl GhCli {
    /// `shutil.which("gh")`.
    pub fn new(executable: Option<PathBuf>) -> Self {
        Self {
            executable: executable.or_else(|| util::which("gh")),
        }
    }
}

impl GitHubApi for GhCli {
    fn executable(&self) -> Option<PathBuf> {
        self.executable.clone()
    }

    fn api(&self, method: &str, endpoint: &str, body: Option<&Value>) -> Result<Value> {
        let Some(executable) = &self.executable else {
            return Err(storage_error(
                "auth_failure",
                "Install GitHub CLI and sign in to connect private storage.",
            ));
        };
        let mut command = Command::new(executable);
        command.args([
            "api",
            "--hostname",
            "github.com",
            "--method",
            method,
            "-H",
            "Accept: application/vnd.github+json",
            endpoint,
        ]);
        if body.is_some() {
            command.args(["--input", "-"]);
        }
        let input = body.map(|body| json::dumps(body).into_bytes());
        let unavailable = || {
            storage_error(
                "pending",
                "GitHub is unavailable. Local files are preserved; retry when online.",
            )
        };
        let output = match run_command(&mut command, input.as_deref(), Duration::from_secs(60)) {
            Ok(Some(output)) => output,
            Ok(None) | Err(_) => return Err(unavailable()),
        };
        if output.status != 0 {
            let diagnostic = String::from_utf8_lossy(&output.stderr);
            let status = diagnostic.match_indices("HTTP ").find_map(|(index, _)| {
                let digits = diagnostic.get(index + 5..index + 8)?;
                let after = diagnostic[index + 8..].chars().next();
                (digits.chars().all(|c| c.is_ascii_digit())
                    && !after.is_some_and(|c| c.is_ascii_digit()))
                .then(|| digits.parse::<u16>().ok())
                .flatten()
            });
            return Err(match status {
                Some(404) => {
                    storage_error("missing", "The GitHub object is missing or inaccessible.")
                }
                Some(401 | 403) => storage_error(
                    "auth_failure",
                    "Sign in to GitHub with access to the private storage repository.",
                ),
                _ if diagnostic.contains("auth login") => storage_error(
                    "auth_failure",
                    "Sign in to GitHub with access to the private storage repository.",
                ),
                Some(409 | 422) => storage_error(
                    "conflict",
                    "GitHub changed during publication; both versions are preserved.",
                ),
                _ => unavailable(),
            });
        }
        std::str::from_utf8(&output.stdout)
            .ok()
            .and_then(json::parse)
            .ok_or_else(|| {
                storage_error(
                    "pending",
                    "GitHub returned an unreadable response; local files are preserved.",
                )
            })
    }
}

/// `GitHubFiles`: the small GitHub surface personal storage needs.
pub struct GitHubFiles {
    pub transport: Box<dyn GitHubApi>,
}

impl GitHubFiles {
    pub fn new(transport: Box<dyn GitHubApi>) -> Self {
        Self { transport }
    }

    pub fn executable(&self) -> Option<PathBuf> {
        self.transport.executable()
    }

    pub fn api(&self, method: &str, endpoint: &str, body: Option<&Value>) -> Result<Value> {
        self.transport.api(method, endpoint, body)
    }

    pub fn account(&self) -> Result<Dict> {
        let user = self.api("GET", "user", None)?;
        let user = user.as_dict().cloned().unwrap_or_default();
        let login = user.get("login").map(Value::py_str).unwrap_or_default();
        let login_valid =
            !login.is_empty() && login.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
        if !user.get("id").is_some_and(Value::truthy) || !login_valid {
            return Err(storage_error(
                "auth_failure",
                "GitHub did not return an authenticated user identity.",
            ));
        }
        let mut account = Dict::new();
        account.insert("id", user.get("id").cloned().unwrap_or(Value::Null));
        account.insert("login", login.as_str());
        account.insert("suggested_repository", format!("{login}-rr-files"));
        Ok(account)
    }

    pub fn repo(&self, full_name: &str) -> Result<Value> {
        self.api("GET", &format!("repos/{full_name}"), None)
    }

    /// Path to blob id for every blob of `commit`'s tree.
    pub fn tree(&self, full_name: &str, commit: &str) -> Result<Dict> {
        let commit_data = self.api(
            "GET",
            &format!("repos/{full_name}/git/commits/{commit}"),
            None,
        )?;
        let tree_sha = field_str(field(&commit_data, "tree")?, "sha")?;
        let data = self.api(
            "GET",
            &format!("repos/{full_name}/git/trees/{tree_sha}?recursive=1"),
            None,
        )?;
        if data
            .as_dict()
            .and_then(|data| data.get("truncated"))
            .is_some_and(Value::truthy)
        {
            return Err(storage_error(
                "conflict",
                "The storage repository tree is too large to validate completely.",
            ));
        }
        let mut blobs = Dict::new();
        for row in field(&data, "tree")?.as_list().unwrap_or_default() {
            if field(row, "type")?.is_str("blob") {
                blobs.insert(&field_str(row, "path")?, field(row, "sha")?.clone());
            }
        }
        Ok(blobs)
    }

    pub fn read_blob(
        &self,
        full_name: &str,
        blob: &str,
        expected_size: Option<i64>,
    ) -> Result<Vec<u8>> {
        let data = self.api("GET", &format!("repos/{full_name}/git/blobs/{blob}"), None)?;
        let dict = data.as_dict().cloned().unwrap_or_default();
        if !dict.get("sha").is_some_and(|sha| sha.is_str(blob))
            || !dict
                .get("encoding")
                .is_some_and(|encoding| encoding.is_str("base64"))
        {
            return Err(storage_error(
                "conflict",
                "Remote file identity or encoding is invalid.",
            ));
        }
        if let Some(size) = expected_size
            && !dict
                .get("size")
                .is_some_and(|actual| json::py_eq(actual, &Value::Int(size)))
        {
            return Err(storage_error(
                "conflict",
                "Remote file size does not match its verified catalog.",
            ));
        }
        let content = dict
            .get("content")
            .and_then(Value::as_str)
            .and_then(|text| b64decode_strict(&text.replace('\n', "")))
            .ok_or_else(|| storage_error("conflict", "Remote file content is invalid."))?;
        if git_blob_id(&content) != blob
            || expected_size.is_some_and(|size| content.len() as i64 != size)
        {
            return Err(storage_error(
                "conflict",
                "Remote file checksum failed. The local copy is preserved.",
            ));
        }
        Ok(content)
    }

    pub fn head(&self, full_name: &str, branch: &str) -> Result<String> {
        let reference = self.api(
            "GET",
            &format!("repos/{full_name}/git/ref/heads/{}", quote(branch)),
            None,
        )?;
        field_str(field(&reference, "object")?, "sha")
    }

    /// Appends one commit. `expected` path blobs detect edits by other
    /// devices; `None` expects the path to be absent or already this content.
    pub fn publish(
        &self,
        full_name: &str,
        branch: &str,
        changes: &[(String, Vec<u8>)],
        expected: &[(String, Option<String>)],
    ) -> Result<String> {
        let head = self.head(full_name, branch)?;
        let existing = self.tree(full_name, &head)?;
        for (path, blob) in expected {
            let current = existing.get(path).and_then(Value::as_str);
            let content = changes
                .iter()
                .find(|(name, _)| name == path)
                .map(|(_, content)| content)
                .ok_or_else(|| key_error(path))?;
            if current != blob.as_deref() && current != Some(git_blob_id(content).as_str()) {
                return Err(storage_error(
                    "conflict",
                    "A remote file changed. Resolve the conflict before uploading.",
                ));
            }
        }
        let mut tree = Vec::new();
        for (path, content) in changes {
            let mut body = Dict::new();
            body.insert("content", b64encode(content));
            body.insert("encoding", "base64");
            let created = self.api(
                "POST",
                &format!("repos/{full_name}/git/blobs"),
                Some(&Value::Dict(body)),
            )?;
            let blob = field_str(&created, "sha")?;
            if blob != git_blob_id(content) {
                return Err(storage_error(
                    "conflict",
                    "GitHub acknowledged an unexpected file revision.",
                ));
            }
            let mut item = Dict::new();
            item.insert("path", path.as_str());
            item.insert("mode", "100644");
            item.insert("type", "blob");
            item.insert("sha", blob);
            tree.push(Value::Dict(item));
        }
        let commit_data = self.api(
            "GET",
            &format!("repos/{full_name}/git/commits/{head}"),
            None,
        )?;
        let base_tree = field_str(field(&commit_data, "tree")?, "sha")?;
        let mut body = Dict::new();
        body.insert("base_tree", base_tree);
        body.insert("tree", Value::List(tree));
        let new_tree = field_str(
            &self.api(
                "POST",
                &format!("repos/{full_name}/git/trees"),
                Some(&Value::Dict(body)),
            )?,
            "sha",
        )?;
        let mut body = Dict::new();
        body.insert("message", "Save Relay personal files");
        body.insert("tree", new_tree);
        body.insert("parents", Value::List(vec![Value::Str(head)]));
        let commit = field_str(
            &self.api(
                "POST",
                &format!("repos/{full_name}/git/commits"),
                Some(&Value::Dict(body)),
            )?,
            "sha",
        )?;
        let mut body = Dict::new();
        body.insert("sha", commit.as_str());
        body.insert("force", false);
        self.api(
            "PATCH",
            &format!("repos/{full_name}/git/refs/heads/{}", quote(branch)),
            Some(&Value::Dict(body)),
        )?;
        let proof = self.tree(full_name, &commit)?;
        for (path, content) in changes {
            let blob = git_blob_id(content);
            if !proof.get(path).is_some_and(|value| value.is_str(&blob))
                || self.read_blob(full_name, &blob, Some(content.len() as i64))? != *content
            {
                return Err(storage_error(
                    "conflict",
                    "Remote publication could not be verified. Local files are preserved.",
                ));
            }
        }
        Ok(commit)
    }
}

/// Python's `threading.RLock`: one owner thread at a time, which may
/// re-enter.
#[derive(Default)]
pub struct ReentrantLock {
    state: Mutex<(Option<ThreadId>, usize)>,
    released: Condvar,
}

pub struct ReentrantGuard<'l> {
    lock: &'l ReentrantLock,
}

impl ReentrantLock {
    pub fn lock(&self) -> ReentrantGuard<'_> {
        let me = thread::current().id();
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        while state.0.is_some_and(|owner| owner != me) {
            state = self
                .released
                .wait(state)
                .unwrap_or_else(|poison| poison.into_inner());
        }
        state.0 = Some(me);
        state.1 += 1;
        ReentrantGuard { lock: self }
    }
}

impl Drop for ReentrantGuard<'_> {
    fn drop(&mut self) {
        let mut state = self
            .lock
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        state.1 -= 1;
        if state.1 == 0 {
            state.0 = None;
            self.lock.released.notify_one();
        }
    }
}

/// The catalog connection with Python `sqlite3`'s transaction rule: a data
/// statement opens a transaction when none is open, and `commit()` ends it.
pub struct CatalogDb {
    connection: Mutex<Connection>,
}

fn is_data_statement(sql: &str) -> bool {
    let word: String = sql
        .trim_start()
        .chars()
        .take_while(char::is_ascii_alphabetic)
        .collect::<String>()
        .to_ascii_uppercase();
    matches!(word.as_str(), "INSERT" | "UPDATE" | "DELETE" | "REPLACE")
}

fn row_dict(statement_columns: &[String], row: &rusqlite::Row<'_>) -> rusqlite::Result<Dict> {
    let mut dict = Dict::new();
    for (index, name) in statement_columns.iter().enumerate() {
        dict.insert(name, sql_to_json(row.get::<_, Sql>(index)?));
    }
    Ok(dict)
}

impl CatalogDb {
    fn connection(&self) -> MutexGuard<'_, Connection> {
        self.connection
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    /// `db.execute(sql, params)` for a statement without rows.
    pub fn execute(&self, sql: &str, params: &[Sql]) -> Result<usize> {
        let connection = self.connection();
        if is_data_statement(sql) && connection.is_autocommit() {
            connection.execute_batch("BEGIN")?;
        }
        Ok(connection.execute(sql, rusqlite::params_from_iter(params.iter()))?)
    }

    /// `db.execute(sql, params).fetchall()` as dictionaries.
    pub fn rows(&self, sql: &str, params: &[Sql]) -> Result<Vec<Dict>> {
        let connection = self.connection();
        let mut statement = connection.prepare(sql)?;
        let columns: Vec<String> = statement.column_names().map(str::to_string).collect();
        let rows = statement
            .query_map(rusqlite::params_from_iter(params.iter()), |row| {
                row_dict(&columns, row)
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// `db.execute(sql, params).fetchone()`.
    pub fn row(&self, sql: &str, params: &[Sql]) -> Result<Option<Dict>> {
        Ok(self.rows(sql, params)?.into_iter().next())
    }

    /// `db.commit()`.
    pub fn commit(&self) -> Result<()> {
        let connection = self.connection();
        if !connection.is_autocommit() {
            connection.execute_batch("COMMIT")?;
        }
        Ok(())
    }

    /// A statement run as written, outside the implicit-transaction rule
    /// (`SAVEPOINT`, `RELEASE`, `ROLLBACK TO`, `PRAGMA`).
    pub fn raw(&self, sql: &str) -> Result<()> {
        let connection = self.connection();
        let mut statement = connection.prepare(sql)?;
        let mut rows = statement.query([])?;
        while rows.next()?.is_some() {}
        Ok(())
    }
}

pub(crate) fn text(value: impl Into<String>) -> Sql {
    Sql::Text(value.into())
}

fn opt_text(value: Option<&str>) -> Sql {
    value.map_or(Sql::Null, |value| Sql::Text(value.to_string()))
}

/// The `files` row a catalog import writes when the identity is new.
fn real(value: f64) -> Sql {
    Sql::Real(value)
}

fn json_number(value: &Value) -> Sql {
    match value {
        Value::Int(number) => Sql::Integer(*number),
        Value::Bool(flag) => Sql::Integer(i64::from(*flag)),
        Value::Float(number) => Sql::Real(*number),
        other => Sql::Text(other.py_str()),
    }
}

type Clock = Box<dyn Fn() -> f64 + Send + Sync>;

/// `PersonalFileStorage`.
pub struct PersonalFileStorage {
    pub root: PathBuf,
    pub files_root: PathBuf,
    pub general_tasks_root: PathBuf,
    pub support_root: PathBuf,
    pub github: GitHubFiles,
    clock: Clock,
    /// `self.lock`, shared with the personal note manager.
    pub lock: ReentrantLock,
    /// `self.db`, shared with the personal note manager.
    pub db: CatalogDb,
    login: Mutex<Option<(Child, PathBuf)>>,
    note_library: Mutex<Weak<GlobalNoteLibrary>>,
}

impl PersonalFileStorage {
    /// `PersonalFileStorage(state_root, github=..., clock=...)`. `None`
    /// selects the `gh` transport and `time.time`.
    pub fn open(
        state_root: &Path,
        github: Option<GitHubFiles>,
        clock: Option<Clock>,
    ) -> Result<Self> {
        let root = resolve(state_root);
        let files_root = root.join("files");
        let general_tasks_root = root.join("general-tasks");
        let support_root = root.join("personal-storage");
        if [&files_root, &support_root, &files_root.join("documents")]
            .iter()
            .any(|path| is_symlink(path))
        {
            return Err(storage_error(
                "conflict",
                "Personal storage folders must not be symbolic links.",
            ));
        }
        fs::create_dir_all(&files_root)?;
        let documents = files_root.join("documents");
        if !documents.is_dir() {
            fs::create_dir(&documents)?;
        }
        if !support_root.is_dir() {
            if let Some(parent) = support_root.parent() {
                fs::create_dir_all(parent)?;
            }
            DirBuilder::new().mode(0o700).create(&support_root)?;
        }
        let path = support_root.join("catalog.sqlite3");
        let connection = Connection::open(&path)?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))?;
        connection.execute_batch(SCHEMA)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        Ok(Self {
            root,
            files_root,
            general_tasks_root,
            support_root,
            github: github.unwrap_or_else(|| GitHubFiles::new(Box::new(GhCli::new(None)))),
            clock: clock.unwrap_or_else(|| Box::new(util::now)),
            lock: ReentrantLock::default(),
            db: CatalogDb {
                connection: Mutex::new(connection),
            },
            login: Mutex::new(None),
            note_library: Mutex::new(Weak::new()),
        })
    }

    pub fn clock(&self) -> f64 {
        (self.clock)()
    }

    /// `attach_notes`: the global library writes into this storage after
    /// migration.
    pub fn attach_notes(self: &Arc<Self>, library: &Arc<GlobalNoteLibrary>) -> Result<()> {
        *self
            .note_library
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()) = Arc::downgrade(library);
        library.set_personal_storage(self.clone());
        if self.get("notes_migrated", Value::Bool(false))?.truthy() {
            library.reset_manager();
        }
        Ok(())
    }

    pub(crate) fn note_library(&self) -> Option<Arc<GlobalNoteLibrary>> {
        self.note_library
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .upgrade()
    }

    /// `_get(key, default)`.
    pub fn get(&self, key: &str, default: Value) -> Result<Value> {
        let row = self
            .db
            .row("SELECT value FROM settings WHERE key=?", &[text(key)])?;
        Ok(match row {
            Some(row) => json::parse(&row.string("value")).unwrap_or(Value::Null),
            None => default,
        })
    }

    /// `_set(key, value)`, inside the open transaction.
    pub fn set(&self, key: &str, value: &Value) -> Result<()> {
        self.db.execute(
            "INSERT OR REPLACE INTO settings VALUES(?,?)",
            &[text(key), text(json::dumps(value))],
        )?;
        Ok(())
    }

    fn set_state(&self, state: &str, message: Option<&str>) -> Result<()> {
        self.set("state", &Value::Str(state.to_string()))?;
        self.set("message", &Value::from(message))?;
        self.db.commit()
    }

    fn connected(&self) -> Result<bool> {
        Ok(self.get("connected", Value::Null)?.truthy())
    }

    pub fn account(&self) -> Result<Dict> {
        let _guard = self.lock.lock();
        self.github.account()
    }

    /// `sign_in`: the user-invoked browser device login. No auth text enters
    /// the file allowlist.
    pub fn sign_in(&self) -> Result<Dict> {
        let _guard = self.lock.lock();
        let Some(executable) = self.github.executable() else {
            return Err(storage_error(
                "auth_failure",
                "Install GitHub CLI to connect private storage.",
            ));
        };
        let mut login = self
            .login
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let running = login
            .as_mut()
            .is_some_and(|(process, _)| matches!(process.try_wait(), Ok(None)));
        if !running {
            let log = self.support_root.join("github-login.txt");
            let handle = File::create(&log)?;
            fs::set_permissions(&log, fs::Permissions::from_mode(0o600))?;
            let process = Command::new(executable)
                .args([
                    "auth",
                    "login",
                    "--hostname",
                    "github.com",
                    "--git-protocol",
                    "https",
                    "--web",
                ])
                .stdin(Stdio::null())
                .stdout(handle.try_clone()?)
                .stderr(handle)
                .env("GH_BROWSER", "/usr/bin/open")
                .spawn()?;
            *login = Some((process, log));
        }
        thread::sleep(Duration::from_millis(150));
        let log = login
            .as_ref()
            .map(|(_, log)| log.clone())
            .unwrap_or_default();
        let output = String::from_utf8_lossy(&fs::read(log)?).into_owned();
        let code = device_code(&output);
        let mut result = Dict::new();
        result.insert("state", "pending");
        result.insert("device_code", code);
        result.insert("url", "https://github.com/login/device");
        Ok(result)
    }

    /// `_identity(repo, account)`: the destination a repository may become.
    fn identity(repo: &Value, account: &Dict) -> Result<Dict> {
        let dict = repo.as_dict().cloned().unwrap_or_default();
        let private = matches!(dict.get("private"), Some(Value::Bool(true)));
        let visibility_private = dict
            .get("visibility")
            .is_none_or(|visibility| visibility.is_str("private"));
        if !private || !visibility_private {
            return Err(storage_error(
                "conflict",
                "Personal storage must be private. This repository was not adopted.",
            ));
        }
        let account_id = account.get("id").cloned().unwrap_or(Value::Null);
        let owner_id = dict
            .get("owner")
            .and_then(Value::as_dict)
            .and_then(|owner| owner.get("id"))
            .cloned()
            .unwrap_or(Value::Null);
        if !json::py_eq(&owner_id, &account_id) {
            return Err(storage_error(
                "conflict",
                "The storage repository must belong to the authenticated GitHub user.",
            ));
        }
        let push = dict
            .get("permissions")
            .and_then(Value::as_dict)
            .and_then(|permissions| permissions.get("push"))
            .is_some_and(Value::truthy);
        if !push {
            return Err(storage_error(
                "auth_failure",
                "The authenticated account cannot write this repository.",
            ));
        }
        let mut identity = Dict::new();
        identity.insert("repository_id", field(repo, "id")?.clone());
        identity.insert("node_id", field(repo, "node_id")?.clone());
        identity.insert("owner_id", account_id);
        identity.insert(
            "login",
            account.get("login").cloned().unwrap_or(Value::Null),
        );
        identity.insert("full_name", field(repo, "full_name")?.clone());
        identity.insert("html_url", field(repo, "html_url")?.clone());
        identity.insert("clone_url", field(repo, "clone_url")?.clone());
        identity.insert("branch", field(repo, "default_branch")?.clone());
        Ok(identity)
    }

    fn marker(owner_id: &Value) -> Value {
        let mut marker = Dict::new();
        marker.insert("schema_version", 1);
        marker.insert("purpose", "relay-runner-personal-files");
        marker.insert("owner_id", owner_id.clone());
        Value::Dict(marker)
    }

    /// `configure(confirm=..., repository_name=..., create=...)`.
    pub fn configure(
        &self,
        confirm: &Value,
        repository_name: Option<&str>,
        create: bool,
    ) -> Result<Dict> {
        if !matches!(confirm, Value::Bool(true)) {
            return Err(storage_error(
                "local_only",
                "Enable private GitHub storage explicitly before creating a repository.",
            ));
        }
        let _guard = self.lock.lock();
        let account = self.github.account()?;
        let name = match repository_name.filter(|name| !name.is_empty()) {
            Some(name) => name.to_string(),
            None => account.string("suggested_repository"),
        };
        if !is_repo_name(&name) {
            return Err(Error::value("Invalid storage repository name"));
        }
        let full_name = format!("{}/{name}", account.string("login"));
        let prior = self.get("destination", Value::Null)?;
        let mut pending = self.get("provisioning", Value::Null)?;
        let repo = match self.github.repo(&full_name) {
            Ok(repo) => repo,
            Err(error) => {
                if state_of(&error) != Some("missing") || !create {
                    return Err(error);
                }
                let request_id = util::uuid4_hex();
                let mut provisioning = Dict::new();
                provisioning.insert("full_name", full_name.as_str());
                provisioning.insert(
                    "owner_id",
                    account.get("id").cloned().unwrap_or(Value::Null),
                );
                provisioning.insert("request_id", request_id.as_str());
                let description = format!("{REPO_DESCRIPTION} ({request_id})");
                provisioning.insert("description", description.as_str());
                pending = Value::Dict(provisioning);
                self.set("provisioning", &pending)?;
                self.db.commit()?;
                let mut body = Dict::new();
                body.insert("name", name.as_str());
                body.insert("private", true);
                body.insert("auto_init", true);
                body.insert("description", description);
                self.github
                    .api("POST", "user/repos", Some(&Value::Dict(body)))?
            }
        };
        let identity = Self::identity(&repo, &account)?;
        let branch = identity.string("branch");
        let head = self.github.head(&full_name, &branch)?;
        let tree = self.github.tree(&full_name, &head)?;
        let account_id = account.get("id").cloned().unwrap_or(Value::Null);
        if let Some(blob) = tree.get(MARKER_PATH) {
            let content = self.github.read_blob(&full_name, &blob.py_str(), None)?;
            let marker = parse_json_bytes(&content)?;
            if !json::py_eq(&marker, &Self::marker(&account_id)) {
                return Err(storage_error(
                    "conflict",
                    "This repository has an unrelated storage identity marker.",
                ));
            }
        } else {
            // Retry an interrupted create only for our own empty, private,
            // identified repository.
            let stored = self.get("provisioning", Value::Null)?;
            if stored.truthy() {
                pending = stored;
            }
            let pending = pending.as_dict().cloned();
            let description = repo
                .as_dict()
                .and_then(|repo| repo.get("description"))
                .cloned();
            let unrelated = match &pending {
                None => true,
                Some(pending) if pending.is_empty() => true,
                Some(pending) => {
                    !pending
                        .get("full_name")
                        .is_some_and(|value| value.is_str(&full_name))
                        || !json::py_eq_optional(pending.get("owner_id"), Some(&account_id))
                        || !json::py_eq_optional(description.as_ref(), pending.get("description"))
                        || tree.iter().any(|(path, _)| path != "README.md")
                }
            };
            if unrelated {
                return Err(storage_error(
                    "conflict",
                    "This existing repository is unrelated. Select a Relay storage repo or a new name.",
                ));
            }
            let marker = json::dumps(&Self::marker(&account_id)).into_bytes();
            self.github.publish(
                &full_name,
                &branch,
                &[(MARKER_PATH.to_string(), marker)],
                &[(MARKER_PATH.to_string(), None)],
            )?;
        }
        let identity_value = Value::Dict(identity.clone());
        if prior.truthy() && !json::py_eq(&prior, &identity_value) {
            // Explicit setup can revalidate a rename of the same identity,
            // but never adopts old proofs for a new repository.
            let repository_id = identity
                .get("repository_id")
                .map(Value::py_str)
                .unwrap_or_default();
            let prior_id = prior
                .as_dict()
                .and_then(|prior| prior.get("repository_id"))
                .cloned();
            if !json::py_eq_optional(prior_id.as_ref(), identity.get("repository_id")) {
                let revisions = self.db.rows(
                    "SELECT local_path FROM versions WHERE remote_repo IS NOT NULL AND remote_repo!=?",
                    &[text(repository_id.as_str())],
                )?;
                for revision in revisions {
                    let local = revision
                        .get("local_path")
                        .and_then(Value::as_str)
                        .filter(|local| !local.is_empty());
                    let present = match local {
                        Some(local) => is_file(&self.cache_path(local)?),
                        None => false,
                    };
                    if !present {
                        return Err(storage_error(
                            "conflict",
                            "Retrieve archived files from the existing storage repository before changing destinations. The existing destination is preserved.",
                        ));
                    }
                }
            }
            self.db.execute(
                "UPDATE versions SET remote_repo=NULL,remote_commit=NULL,remote_blob=NULL WHERE remote_repo!=?",
                &[text(repository_id)],
            )?;
        }
        self.set("destination", &identity_value)?;
        self.set("connected", &Value::Bool(true))?;
        self.set("provisioning", &Value::Null)?;
        self.import_catalog(&identity)?;
        self.set_state(
            "pending",
            Some("Select and approve the personal files to synchronize."),
        )?;
        self.status()
    }

    fn remote_catalog(&self, destination: &Dict) -> Result<(Option<Dict>, Option<String>)> {
        let full_name = destination.string("full_name");
        let head = self
            .github
            .head(&full_name, &destination.string("branch"))?;
        let tree = self.github.tree(&full_name, &head)?;
        let Some(blob) = tree
            .get(CATALOG_PATH)
            .filter(|blob| blob.truthy())
            .map(Value::py_str)
        else {
            return Ok((None, None));
        };
        let catalog = parse_json_bytes(&self.github.read_blob(&full_name, &blob, None)?)?;
        let valid = catalog.as_dict().is_some_and(|catalog| {
            json::py_eq_optional(catalog.get("schema_version"), Some(&Value::Int(1)))
                && json::py_eq_optional(
                    catalog.get("repository_id"),
                    destination.get("repository_id"),
                )
                && json::py_eq_optional(catalog.get("owner_id"), destination.get("owner_id"))
        });
        if !valid {
            return Err(storage_error(
                "conflict",
                "The portable file catalog belongs to another repository or account.",
            ));
        }
        Ok((catalog.as_dict().cloned(), Some(blob)))
    }

    fn import_catalog(&self, destination: &Dict) -> Result<()> {
        // A rejected remote catalog must not replace any current pointers,
        // notes or receipts.
        self.db.raw("SAVEPOINT personal_catalog_import")?;
        if let Err(error) = self.apply_catalog(destination) {
            self.db.raw("ROLLBACK TO personal_catalog_import")?;
            self.db.raw("RELEASE personal_catalog_import")?;
            if error.class == "StorageError" {
                return Err(error);
            }
            if matches!(
                error.class,
                "ValueError" | "KeyError" | "TypeError" | "sqlite3.Error"
            ) || error.class.starts_with("Artifact")
                || error.class == "NoteContractError"
            {
                return Err(storage_error(
                    "conflict",
                    "The remote file catalog is invalid. The previous local catalog and content are preserved.",
                ));
            }
            return Err(error);
        }
        self.db.raw("RELEASE personal_catalog_import")?;
        self.db.commit()
    }

    fn apply_catalog(&self, destination: &Dict) -> Result<()> {
        let (catalog, blob) = self.remote_catalog(destination)?;
        let Some(catalog) = catalog else {
            self.set("remote_catalog_blob", &Value::Null)?;
            return Ok(());
        };
        let list = |key: &str| -> Result<Vec<Value>> {
            match catalog.get(key) {
                None => Ok(Vec::new()),
                Some(Value::List(items)) => Ok(items.clone()),
                Some(_) => Err(storage_error(
                    "conflict",
                    "The remote file catalog has an invalid collection; local content is preserved.",
                )),
            }
        };
        let files = list("files")?;
        let notes = list("notes")?;
        let receipts = list("note_events")?;
        let repository_id = destination
            .get("repository_id")
            .map(Value::py_str)
            .unwrap_or_default();
        for file in &files {
            let Some(versions) = file
                .as_dict()
                .and_then(|file| file.get("versions"))
                .and_then(Value::as_list)
            else {
                return Err(storage_error(
                    "conflict",
                    "The remote file catalog has an invalid file or version list; local content is preserved.",
                ));
            };
            let identity = field_str(file, "artifact_id")?;
            let current = field_str(file, "current_sha")?;
            if !is_id(&identity) || !is_hex(&current, 64) {
                return Err(storage_error(
                    "conflict",
                    "Remote file catalog contains an invalid identity.",
                ));
            }
            let category = field_str(file, "category")?;
            let logical = logical_path(&field_str(file, "logical_path")?, &category)?;
            let existing = self.db.row(
                "SELECT * FROM files WHERE artifact_id=?",
                &[text(identity.as_str())],
            )?;
            if let Some(existing) = &existing
                && (existing.string("logical_path") != logical
                    || existing.string("category") != category)
            {
                return Err(storage_error(
                    "conflict",
                    "A remote file identity collides with local content.",
                ));
            }
            let baseline = self.get(&format!("remote_current:{identity}"), Value::Null)?;
            let baseline = baseline.as_str().map(str::to_string);
            let metadata = file
                .as_dict()
                .and_then(|file| file.get("metadata"))
                .cloned()
                .unwrap_or_else(|| Value::Dict(Dict::new()));
            let updated = file
                .as_dict()
                .and_then(|file| file.get("updated"))
                .map(json_number)
                .unwrap_or_else(|| real(self.clock()));
            if let Some(existing) = &existing {
                let local = existing.string("current_sha");
                if local != current
                    && Some(&current) != baseline.as_ref()
                    && Some(&local) != baseline.as_ref()
                {
                    return Err(storage_error(
                        "conflict",
                        "The remote and local current revisions differ. Both copies are preserved for resolution.",
                    ));
                }
            }
            match &existing {
                None => {
                    self.db.execute(
                        "INSERT INTO files VALUES(?,?,?,?,?,0,0,1,?)",
                        &[
                            text(identity.as_str()),
                            text(logical.as_str()),
                            text(category.as_str()),
                            text(current.as_str()),
                            text(json::dumps(&metadata)),
                            updated,
                        ],
                    )?;
                }
                Some(existing)
                    if Some(existing.string("current_sha")) == baseline
                        && Some(&current) != baseline.as_ref() =>
                {
                    self.db.execute(
                        "UPDATE files SET current_sha=?,metadata=?,updated=? WHERE artifact_id=?",
                        &[
                            text(current.as_str()),
                            text(json::dumps(&metadata)),
                            updated,
                            text(identity.as_str()),
                        ],
                    )?;
                }
                Some(_) => {}
            }
            for revision in versions {
                let sha = field_str(revision, "sha256")?;
                let remote_blob = field_str(revision, "remote_blob")?;
                let remote_commit = field_str(revision, "remote_commit")?;
                let size = match field(revision, "size")? {
                    Value::Int(size) if *size >= 0 => *size,
                    _ => -1,
                };
                if !is_hex(&sha, 64)
                    || !is_hex(&remote_blob, 40)
                    || !is_hex(&remote_commit, 40)
                    || size < 0
                {
                    return Err(storage_error(
                        "conflict",
                        "Remote file catalog contains an invalid revision proof.",
                    ));
                }
                self.db.execute(
                    "INSERT INTO versions VALUES(?,?,?,NULL,?,?,?,?) ON CONFLICT(artifact_id,sha256)
                    DO UPDATE SET remote_repo=excluded.remote_repo,remote_commit=excluded.remote_commit,remote_blob=excluded.remote_blob",
                    &[
                        text(identity.as_str()),
                        text(sha),
                        Sql::Integer(size),
                        text(repository_id.as_str()),
                        text(remote_commit),
                        text(remote_blob),
                        real(self.clock()),
                    ],
                )?;
            }
            self.reference(&identity, Some(&current))?;
            if category == "documents" {
                self.set(
                    &format!("source_path:{identity}"),
                    &Value::Str(format!("files/{logical}")),
                )?;
            }
            self.set(&format!("remote_current:{identity}"), &Value::Str(current))?;
        }
        if !notes.is_empty() {
            let manager = PersonalNoteManager::open(self, "remote-catalog", false)?;
            for entry in &notes {
                let artifact_id = field_str(entry, "artifact_id")?;
                self.reference(&artifact_id, None)?;
                let local = self.db.row(
                    "SELECT entry,deleted FROM personal_notes WHERE artifact_id=?",
                    &[text(artifact_id.as_str())],
                )?;
                let local_entry = match &local {
                    Some(local) => {
                        let mut parsed = json::parse(&local.string("entry"))
                            .and_then(|value| value.as_dict().cloned())
                            .ok_or_else(|| Error::value("Expecting value"))?;
                        parsed.insert("legacy_recovery", Value::Null);
                        parsed.insert("deleted", local.get("deleted").is_some_and(Value::truthy));
                        Some(Value::Dict(parsed))
                    }
                    None => None,
                };
                let baseline = self.get(&format!("remote_note:{artifact_id}"), Value::Null)?;
                if let Some(local_entry) = &local_entry
                    && !json::py_eq(local_entry, entry)
                    && !json::py_eq(local_entry, &baseline)
                    && !json::py_eq(entry, &baseline)
                {
                    return Err(storage_error(
                        "conflict",
                        "Another device changed this note's metadata or deletion state. Both histories are preserved.",
                    ));
                }
                if local_entry
                    .as_ref()
                    .is_none_or(|local| json::py_eq(local, &baseline))
                {
                    let entry_dict = entry.as_dict().cloned().unwrap_or_default();
                    if let Err(error) = manager.import_remote_entry(&entry_dict, false) {
                        if error.class == "ValueError"
                            || error.class == "NoteContractError"
                            || error.class.starts_with("Artifact")
                        {
                            return Err(storage_error(
                                "conflict",
                                "Remote note identities collide with local notes; both histories are preserved.",
                            ));
                        }
                        return Err(error);
                    }
                }
                self.set(&format!("remote_note:{artifact_id}"), entry)?;
            }
            for receipt in &receipts {
                let receipt_dict = receipt.as_dict().cloned().unwrap_or_default();
                let event_id = receipt_dict
                    .get("event_id")
                    .map(Value::py_str)
                    .unwrap_or_default();
                let digest = receipt_dict
                    .get("digest")
                    .map(Value::py_str)
                    .unwrap_or_default();
                let event_valid = (1..=512).contains(&event_id.len())
                    && event_id
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':' | '-'));
                if !event_valid || !is_hex(&digest, 64) {
                    return Err(storage_error(
                        "conflict",
                        "The remote note request receipt is invalid.",
                    ));
                }
                let artifact_id = field_str(receipt, "artifact_id")?;
                let revision_id = field_str(receipt, "revision")?;
                let revision = self.reference(&artifact_id, Some(&revision_id))?;
                if !revision
                    .get("category")
                    .is_some_and(|category| category.is_str("notes"))
                    || !revision.get("remote_commit").is_some_and(Value::truthy)
                {
                    return Err(storage_error(
                        "conflict",
                        "The remote note request receipt has no immutable note version.",
                    ));
                }
                let prior = self.db.row(
                    "SELECT * FROM personal_note_events WHERE event_id=?",
                    &[text(event_id.as_str())],
                )?;
                if let Some(prior) = prior
                    && !json::py_eq(&Value::Dict(prior), receipt)
                {
                    return Err(storage_error(
                        "conflict",
                        "A remote note request receipt collides with a local request; both histories are preserved.",
                    ));
                }
                self.db.execute(
                    "INSERT OR IGNORE INTO personal_note_events VALUES(?,?,?,?)",
                    &[
                        text(event_id),
                        text(digest),
                        text(artifact_id),
                        text(revision_id),
                    ],
                )?;
            }
            let next = manager.next_number()?.max(
                catalog
                    .get("next_note_id")
                    .and_then(Value::py_int)
                    .unwrap_or(1),
            );
            self.set("next_personal_note_id", &Value::Int(next))?;
            // An existing legacy library is migrated by the verified bundle flow.
            if !self.root.join("notes").join(".git").exists() {
                self.set("notes_migrated", &Value::Bool(true))?;
                if let Some(library) = self.note_library() {
                    library.reset_manager();
                }
            }
        }
        self.set("remote_catalog_blob", &Value::from(blob))?;
        Ok(())
    }

    fn table_exists(&self, name: &str) -> Result<bool> {
        Ok(self
            .db
            .row("SELECT 1 FROM sqlite_master WHERE name=?", &[text(name)])?
            .is_some())
    }

    fn publish_catalog(&self, destination: &Dict) -> Result<()> {
        // Import newly published identities and unchanged-local remote
        // updates before merging.
        self.import_catalog(destination)?;
        let (remote, expected_blob) = self.remote_catalog(destination)?;
        let remote = remote.unwrap_or_default();
        let remote_list = |key: &str| -> Vec<Value> {
            remote
                .get(key)
                .and_then(Value::as_list)
                .map(<[Value]>::to_vec)
                .unwrap_or_default()
        };
        let repository_id = destination
            .get("repository_id")
            .map(Value::py_str)
            .unwrap_or_default();
        let mut by_id = Dict::new();
        for file in remote_list("files") {
            by_id.insert(&field_str(&file, "artifact_id")?, file);
        }
        let approved = self
            .db
            .rows("SELECT * FROM files WHERE approved=1 AND active=0", &[])?;
        for row in approved {
            let artifact_id = row.string("artifact_id");
            let versions = self.db.rows(
                "SELECT sha256,size,remote_commit,remote_blob FROM versions
                WHERE artifact_id=? AND remote_repo=? AND remote_commit IS NOT NULL",
                &[text(artifact_id.as_str()), text(repository_id.as_str())],
            )?;
            let current = row.string("current_sha");
            if versions.is_empty()
                || !versions
                    .iter()
                    .any(|version| version.string("sha256") == current)
            {
                continue;
            }
            let mut versions: Vec<Value> = versions.into_iter().map(Value::Dict).collect();
            if let Some(prior) = by_id.get(&artifact_id).cloned() {
                let prior_current = field_str(&prior, "current_sha")?;
                let baseline = self.get(&format!("remote_current:{artifact_id}"), Value::Null)?;
                if prior_current != current && !baseline.is_str(&prior_current) {
                    return Err(storage_error(
                        "conflict",
                        "Another device changed the current file revision. Both histories are preserved.",
                    ));
                }
                let mut merged = Dict::new();
                let prior_versions = field(&prior, "versions")?
                    .as_list()
                    .unwrap_or_default()
                    .to_vec();
                for version in prior_versions.into_iter().chain(versions) {
                    merged.insert(&field_str(&version, "sha256")?, version);
                }
                versions = merged.iter().map(|(_, version)| version.clone()).collect();
            }
            let mut metadata =
                json::parse(&row.string("metadata")).unwrap_or(Value::Dict(Dict::new()));
            if let Some(Value::Dict(entry)) = metadata
                .as_dict()
                .and_then(|metadata| metadata.get("note_entry"))
                .cloned()
            {
                let mut entry = entry;
                entry.insert("legacy_recovery", Value::Null);
                let mut wrapped = Dict::new();
                wrapped.insert("note_entry", entry);
                metadata = Value::Dict(wrapped);
            }
            let mut file = Dict::new();
            file.insert("artifact_id", artifact_id.as_str());
            file.insert(
                "logical_path",
                row.get("logical_path").cloned().unwrap_or(Value::Null),
            );
            file.insert(
                "category",
                row.get("category").cloned().unwrap_or(Value::Null),
            );
            file.insert("current_sha", current.as_str());
            file.insert("metadata", metadata);
            file.insert(
                "updated",
                row.get("updated").cloned().unwrap_or(Value::Null),
            );
            file.insert("versions", Value::List(versions));
            by_id.insert(&artifact_id, file);
        }
        let mut notes_by_id = Dict::new();
        for entry in remote_list("notes") {
            notes_by_id.insert(&field_str(&entry, "artifact_id")?, entry);
        }
        if self.table_exists("personal_notes")? {
            let rows = self.db.rows(
                "SELECT n.entry,n.deleted FROM personal_notes n JOIN files f USING(artifact_id) WHERE f.active=0",
                &[],
            )?;
            for row in rows {
                let mut entry = json::parse(&row.string("entry"))
                    .and_then(|value| value.as_dict().cloned())
                    .unwrap_or_default();
                let artifact_id = entry.string("artifact_id");
                if by_id.get(&artifact_id).is_some() {
                    entry.insert("legacy_recovery", Value::Null);
                    entry.insert("deleted", row.get("deleted").is_some_and(Value::truthy));
                    notes_by_id.insert(&artifact_id, entry);
                }
            }
        }
        let mut receipts = Dict::new();
        for row in remote_list("note_events") {
            receipts.insert(&field_str(&row, "event_id")?, row);
        }
        if self.table_exists("personal_note_events")? {
            for row in self.db.rows("SELECT * FROM personal_note_events", &[])? {
                let Some(file) = by_id.get(&row.string("artifact_id")) else {
                    continue;
                };
                let revision = row.string("revision");
                let known = field(file, "versions")?
                    .as_list()
                    .unwrap_or_default()
                    .iter()
                    .any(|version| {
                        version
                            .as_dict()
                            .is_some_and(|version| version.string("sha256") == revision)
                    });
                if known {
                    let event_id = row.string("event_id");
                    let row = Value::Dict(row);
                    if let Some(existing) = receipts.get(&event_id)
                        && !json::py_eq(existing, &row)
                    {
                        return Err(storage_error(
                            "conflict",
                            "A remote note request receipt conflicts with a local request.",
                        ));
                    }
                    receipts.insert(&event_id, row);
                }
            }
        }
        let mut catalog = Dict::new();
        catalog.insert("schema_version", 1);
        catalog.insert(
            "repository_id",
            destination
                .get("repository_id")
                .cloned()
                .unwrap_or(Value::Null),
        );
        catalog.insert(
            "owner_id",
            destination.get("owner_id").cloned().unwrap_or(Value::Null),
        );
        catalog.insert(
            "files",
            Value::List(by_id.iter().map(|(_, file)| file.clone()).collect()),
        );
        catalog.insert(
            "notes",
            Value::List(notes_by_id.iter().map(|(_, note)| note.clone()).collect()),
        );
        catalog.insert(
            "note_events",
            Value::List(
                receipts
                    .iter()
                    .map(|(_, receipt)| receipt.clone())
                    .collect(),
            ),
        );
        catalog.insert(
            "next_note_id",
            self.get("next_personal_note_id", Value::Int(1))?,
        );
        let content = json::dumps_sorted(&Value::Dict(catalog)).into_bytes();
        self.github.publish(
            &destination.string("full_name"),
            &destination.string("branch"),
            &[(CATALOG_PATH.to_string(), content.clone())],
            &[(CATALOG_PATH.to_string(), expected_blob)],
        )?;
        self.set("remote_catalog_blob", &Value::Str(git_blob_id(&content)))?;
        for (identity, file) in by_id.iter() {
            self.set(
                &format!("remote_current:{identity}"),
                field(file, "current_sha")?,
            )?;
        }
        for (identity, entry) in notes_by_id.iter() {
            self.set(&format!("remote_note:{identity}"), entry)?;
        }
        self.db.commit()
    }

    pub fn disconnect(&self) -> Result<Dict> {
        let _guard = self.lock.lock();
        self.set("connected", &Value::Bool(false))?;
        self.set_state(
            "disconnected",
            Some("Uploads are stopped. Local and remote files are preserved."),
        )?;
        self.status()
    }

    /// `_validate_destination`: the connected destination, revalidated with
    /// GitHub.
    pub fn validate_destination(&self) -> Result<Dict> {
        let destination = self.get("destination", Value::Null)?;
        if !self.connected()? || !destination.truthy() {
            return Err(storage_error(
                "disconnected",
                "Connect private GitHub storage to publish or retrieve files.",
            ));
        }
        let destination = destination.as_dict().cloned().unwrap_or_default();
        let account = self.github.account()?;
        let full_name = destination.string("full_name");
        let repo = self.github.repo(&full_name)?;
        if !json::py_eq(
            &Value::Dict(Self::identity(&repo, &account)?),
            &Value::Dict(destination.clone()),
        ) {
            return Err(storage_error(
                "conflict",
                "GitHub account, repository identity, privacy or destination changed. Reconnect to revalidate.",
            ));
        }
        let head = self
            .github
            .head(&full_name, &destination.string("branch"))?;
        let tree = self.github.tree(&full_name, &head)?;
        let marker_ok = match tree.get(MARKER_PATH).filter(|marker| marker.truthy()) {
            Some(marker) => {
                let content = self.github.read_blob(&full_name, &marker.py_str(), None)?;
                let owner = destination.get("owner_id").cloned().unwrap_or(Value::Null);
                json::py_eq(&parse_json_bytes(&content)?, &Self::marker(&owner))
            }
            None => false,
        };
        if !marker_ok {
            return Err(storage_error(
                "conflict",
                "The repository storage marker changed. Reconnect to revalidate.",
            ));
        }
        Ok(destination)
    }

    /// `_cache_path(relative)`: a path inside the managed files root with no
    /// symbolic link on the way.
    pub fn cache_path(&self, relative_path: &str) -> Result<PathBuf> {
        let path = self.root.join(relative_path);
        let mut linked = false;
        let mut current = Some(path.as_path());
        while let Some(candidate) = current {
            if candidate != self.root && is_symlink(candidate) {
                linked = true;
            }
            current = candidate.parent();
        }
        if !resolve(&path).starts_with(&self.files_root) || linked {
            return Err(storage_error(
                "conflict",
                "The local cache path is not a managed personal file. Content is preserved.",
            ));
        }
        Ok(path)
    }

    fn durable_directory(&self, directory: &Path) -> Result<()> {
        // Adoption may remove a source only after the cache name and parents
        // are durable.
        let mut directory = directory.to_path_buf();
        while directory.starts_with(&self.files_root) {
            fsync(&File::open(&directory)?)?;
            if !directory.pop() {
                break;
            }
        }
        Ok(())
    }

    /// `put(...)`: cache `content` as the identity's current version.
    #[allow(clippy::too_many_arguments)]
    pub fn put(
        &self,
        artifact_id: &str,
        logical: &str,
        content: &[u8],
        category: &str,
        metadata: Option<&Value>,
        active: bool,
        approved: Option<bool>,
        commit: bool,
    ) -> Result<Dict> {
        if !is_id(artifact_id) {
            return Err(Error::value("Invalid personal file identity"));
        }
        let logical = logical_path(logical, category)?;
        let digest = sha256::hex_digest(content);
        let _guard = self.lock.lock();
        let prior = self.db.row(
            "SELECT * FROM files WHERE artifact_id=?",
            &[text(artifact_id)],
        )?;
        if let Some(prior) = &prior
            && (prior.string("logical_path") != logical || prior.string("category") != category)
        {
            return Err(Error::value(
                "Personal file identity cannot change its path or category",
            ));
        }
        let path = self
            .files_root
            .join(category)
            .join(artifact_id)
            .join(format!("{digest}{}", suffix(&logical)));
        self.cache_path(&relative(&path, &self.root))?;
        fs::create_dir_all(path.parent().expect("cache parent"))?;
        let temporary = write_temporary(&path, content)?;
        let placed = fs::rename(&temporary, &path)
            .map_err(Error::from)
            .and_then(|()| self.durable_directory(path.parent().expect("cache parent")));
        let _ = fs::remove_file(&temporary);
        placed?;
        let empty = Value::Dict(Dict::new());
        let metadata = metadata
            .filter(|metadata| metadata.truthy())
            .unwrap_or(&empty);
        let pinned = prior
            .as_ref()
            .and_then(|prior| prior.get("pinned"))
            .and_then(Value::py_int)
            .unwrap_or(0);
        let approved = approved.unwrap_or_else(|| {
            prior
                .as_ref()
                .is_some_and(|prior| prior.get("approved").is_some_and(Value::truthy))
        });
        self.db.execute(
            "INSERT INTO files VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(artifact_id) DO UPDATE SET
                current_sha=excluded.current_sha,metadata=excluded.metadata,active=excluded.active,
                approved=excluded.approved,updated=excluded.updated",
            &[
                text(artifact_id),
                text(logical.as_str()),
                text(category),
                text(digest.as_str()),
                text(json::dumps(metadata)),
                Sql::Integer(pinned),
                Sql::Integer(i64::from(active)),
                Sql::Integer(i64::from(approved)),
                real(self.clock()),
            ],
        )?;
        self.db.execute(
            "INSERT INTO versions VALUES(?,?,?,?,NULL,NULL,NULL,?) ON CONFLICT(artifact_id,sha256)
                DO UPDATE SET local_path=excluded.local_path,accessed=excluded.accessed",
            &[
                text(artifact_id),
                text(digest.as_str()),
                Sql::Integer(content.len() as i64),
                text(relative(&path, &self.root)),
                real(self.clock()),
            ],
        )?;
        if self.connected()? {
            self.set("state", &Value::Str("pending".into()))?;
        }
        if commit {
            self.db.commit()?;
        }
        self.reference(artifact_id, None)
    }

    /// `register_file(path, ...)`: catalog a file under the files root.
    pub fn register_file(
        &self,
        path: &Path,
        artifact_id: Option<&str>,
        active: bool,
        approved: bool,
        adopt: bool,
    ) -> Result<Dict> {
        if !path.exists()
            && let Some(artifact_id) = artifact_id.filter(|id| !id.is_empty())
        {
            return self.reference(artifact_id, None);
        }
        if is_symlink(path) {
            return Err(Error::value(
                "Symbolic links cannot be selected for private storage",
            ));
        }
        let source = resolve(path);
        let relative_path = source.strip_prefix(&self.files_root).map_err(|_| {
            Error::value(format!(
                "{} is not in the subpath of {}",
                json::str_repr(&source.to_string_lossy()),
                json::str_repr(&self.files_root.to_string_lossy())
            ))
        })?;
        let relative_text = relative_path.to_string_lossy().into_owned();
        let category = relative_text
            .split('/')
            .next()
            .unwrap_or_default()
            .to_string();
        let content = fs::read(&source)?;
        let identity = match artifact_id.filter(|id| !id.is_empty()) {
            Some(id) => id.to_string(),
            None => format!(
                "file-{}",
                &sha256::hex_digest(relative_text.as_bytes())[..40]
            ),
        };
        let reference = self.put(
            &identity,
            &relative_text,
            &content,
            &category,
            None,
            active,
            Some(approved),
            true,
        )?;
        if adopt && source != self.root.join(reference.string("local_path")) {
            if self.read(&reference.string("artifact_id"), None)? != content
                || fs::read(&source)? != content
            {
                return Err(storage_error(
                    "conflict",
                    "The task file changed while being adopted; both copies are preserved.",
                ));
            }
            fs::remove_file(&source)?;
        }
        Ok(reference)
    }

    /// `discover_documents`: catalog foreground user documents; runtime and
    /// immutable cache paths are excluded.
    pub fn discover_documents(&self) -> Result<()> {
        let _guard = self.lock.lock();
        let managed: Vec<String> = self
            .db
            .rows(
                "SELECT artifact_id FROM files WHERE category='documents'",
                &[],
            )?
            .into_iter()
            .map(|row| row.string("artifact_id"))
            .collect();
        for (root, category) in [
            (self.files_root.join("documents"), "documents"),
            (self.general_tasks_root.clone(), "tasks"),
        ] {
            if is_symlink(&root) || !root.is_dir() {
                continue;
            }
            let general = root == self.general_tasks_root;
            walk(&root, &mut |folder, dirs, names| {
                dirs.retain(|name| {
                    let cache = !general && folder == root && managed.contains(name);
                    !(name.starts_with('.') || is_symlink(&folder.join(name)) || cache)
                });
                for name in names {
                    let source = folder.join(name);
                    if name.starts_with('.')
                        || is_symlink(&source)
                        || !is_file(&source)
                        || is_cache_name(name)
                    {
                        continue;
                    }
                    let logical = if general {
                        format!("tasks/general-tasks/{}", relative(&source, &root))
                    } else {
                        relative(&source, &self.files_root)
                    };
                    if logical_path(&logical, category).is_err() {
                        continue;
                    }
                    let prior = self.db.row(
                        "SELECT artifact_id,current_sha FROM files WHERE logical_path=?",
                        &[text(logical.as_str())],
                    )?;
                    let identity = match &prior {
                        Some(prior) => prior.string("artifact_id"),
                        None => {
                            format!("document-{}", &sha256::hex_digest(logical.as_bytes())[..40])
                        }
                    };
                    let Ok(content) = fs::read(&source) else {
                        // A foreground writer may be replacing or removing
                        // this document.
                        continue;
                    };
                    if prior.as_ref().is_none_or(|prior| {
                        prior.string("current_sha") != sha256::hex_digest(&content)
                    }) {
                        self.put(
                            &identity,
                            &logical,
                            &content,
                            category,
                            None,
                            false,
                            Some(false),
                            true,
                        )?;
                    }
                    self.set(
                        &format!("source_path:{identity}"),
                        &Value::Str(relative(&source, &self.root)),
                    )?;
                }
                Ok(())
            })?;
        }
        self.db.commit()
    }

    fn source_path(&self, artifact_id: &str) -> Result<Option<PathBuf>> {
        let relative_value = self.get(&format!("source_path:{artifact_id}"), Value::Null)?;
        let Some(relative_path) = relative_value.as_str().filter(|path| !path.is_empty()) else {
            return Ok(None);
        };
        if relative_path.split('/').find(|part| !part.is_empty()) == Some("general-tasks") {
            logical_path(&format!("tasks/{relative_path}"), "tasks")?;
            let path = self.root.join(relative_path);
            let mut linked = false;
            let mut current = Some(path.as_path());
            while let Some(candidate) = current {
                if candidate != self.root && is_symlink(candidate) {
                    linked = true;
                }
                current = candidate.parent();
            }
            if !resolve(&path).starts_with(&self.general_tasks_root) || linked {
                return Err(storage_error(
                    "conflict",
                    "The general-tasks source path changed. Content is preserved.",
                ));
            }
            return Ok(Some(path));
        }
        Ok(Some(self.cache_path(relative_path)?))
    }

    fn restore_source(&self, artifact_id: &str, digest: &str, content: &[u8]) -> Result<()> {
        let current = self
            .db
            .row(
                "SELECT current_sha FROM files WHERE artifact_id=?",
                &[text(artifact_id)],
            )?
            .map(|row| row.string("current_sha"));
        let Some(source) = self.source_path(artifact_id)? else {
            return Ok(());
        };
        if current.as_deref() != Some(digest) || source.exists() {
            return Ok(());
        }
        fs::create_dir_all(source.parent().expect("source parent"))?;
        let temporary = write_temporary(&source, content)?;
        // A hard link is exclusive: a document created while downloading is
        // never replaced.
        let linked = match fs::hard_link(&temporary, &source) {
            Ok(()) => self.durable_directory(source.parent().expect("source parent")),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
            Err(error) => Err(error.into()),
        };
        let _ = fs::remove_file(&temporary);
        linked
    }

    /// `reference(artifact_id, sha256)`: one version with its file identity.
    pub fn reference(&self, artifact_id: &str, sha256: Option<&str>) -> Result<Dict> {
        let _guard = self.lock.lock();
        let row = self.db.row(
            "SELECT v.*,f.logical_path,f.category,f.metadata,f.pinned,f.active,f.approved
                FROM versions v JOIN files f USING(artifact_id)
                WHERE v.artifact_id=? AND v.sha256=COALESCE(?,f.current_sha)",
            &[text(artifact_id), opt_text(sha256)],
        )?;
        let Some(mut result) = row else {
            return Err(Error::value("Unknown personal file identity or revision"));
        };
        let metadata = json::parse(&result.string("metadata")).unwrap_or(Value::Null);
        result.insert("metadata", metadata);
        let local = result
            .get("local_path")
            .and_then(Value::as_str)
            .filter(|local| !local.is_empty())
            .map(str::to_string);
        let materialized = match local {
            Some(local) => is_file(&self.cache_path(&local)?),
            None => false,
        };
        result.insert("materialized", materialized);
        let source = self.source_path(artifact_id)?;
        result.insert(
            "source_path",
            source
                .filter(|source| is_file(source))
                .map(|source| relative(&source, &self.root)),
        );
        Ok(result)
    }

    pub fn list_files(&self, query: &str) -> Result<Dict> {
        self.discover_documents()?;
        let _guard = self.lock.lock();
        let pattern = format!("%{query}%");
        let rows = self.db.rows(
            "SELECT artifact_id FROM files WHERE artifact_id LIKE ? OR logical_path LIKE ? OR metadata LIKE ? ORDER BY updated DESC",
            &[text(pattern.as_str()), text(pattern.as_str()), text(pattern)],
        )?;
        let mut files = Vec::new();
        for row in rows {
            files.push(Value::Dict(
                self.reference(&row.string("artifact_id"), None)?,
            ));
        }
        let mut result = Dict::new();
        result.insert("files", Value::List(files));
        Ok(result)
    }

    pub fn pin(&self, artifact_id: &str, pinned: bool) -> Result<Dict> {
        let _guard = self.lock.lock();
        self.reference(artifact_id, None)?;
        self.db.execute(
            "UPDATE files SET pinned=? WHERE artifact_id=?",
            &[Sql::Integer(i64::from(pinned)), text(artifact_id)],
        )?;
        self.db.commit()?;
        self.reference(artifact_id, None)
    }

    pub fn approve(&self, artifact_ids: &[String]) -> Result<()> {
        let _guard = self.lock.lock();
        for identity in artifact_ids {
            self.reference(identity, None)?;
            self.db.execute(
                "UPDATE files SET approved=1 WHERE artifact_id=? AND active=0",
                &[text(identity.as_str())],
            )?;
        }
        self.db.commit()
    }

    /// `sync(approve=..., artifact_ids=...)`.
    pub fn sync(&self, approve: &Value, artifact_ids: Option<&[String]>) -> Result<Dict> {
        self.discover_documents()?;
        let approve = matches!(approve, Value::Bool(true));
        let library = self.note_library();
        if let Some(library) = &library
            && self.connected()?
            && approve
            && let Err(error) = library.prepare_personal_storage(self)
        {
            if matches!(
                error.class,
                "OSError" | "CalledProcessError" | "SubprocessError"
            ) {
                let _guard = self.lock.lock();
                self.set_state(
                    "pending",
                    Some("Notes history could not be prepared. Local notes and history are preserved; retry synchronization."),
                )?;
                return self.status();
            }
            return Err(error);
        }
        {
            let _guard = self.lock.lock();
            if approve {
                let identities = match artifact_ids {
                    Some(ids) => ids.to_vec(),
                    None => self
                        .db
                        .rows("SELECT artifact_id FROM files", &[])?
                        .into_iter()
                        .map(|row| row.string("artifact_id"))
                        .collect(),
                };
                self.approve(&identities)?;
            }
            match self.upload_approved() {
                Ok(()) => self.set_state("synced", None)?,
                Err(error) if error.class == "StorageError" => {
                    let state = match state_of(&error) {
                        Some("missing") | None => "auth_failure",
                        Some(state) => state,
                    };
                    self.set_state(state, Some(&error.message))?;
                }
                Err(error) => return Err(error),
            }
        }
        if let Some(library) = &library
            && self.get("state", Value::Null)?.is_str("synced")
            && let Err(error) = library.finalize_personal_storage(self)
        {
            if matches!(
                error.class,
                "OSError"
                    | "StorageError"
                    | "ValueError"
                    | "CalledProcessError"
                    | "SubprocessError"
            ) {
                let _guard = self.lock.lock();
                let state = if error.class == "StorageError" {
                    error.state.clone().unwrap_or_default()
                } else {
                    "pending".to_string()
                };
                self.set_state(
                    &state,
                    Some("Local notes cleanup is pending. Notes and their verified history are preserved; retry synchronization."),
                )?;
            } else {
                return Err(error);
            }
        }
        if self.get("state", Value::Null)?.is_str("synced") {
            self.enforce_retention()?;
            let _guard = self.lock.lock();
            if self
                .db
                .row(
                    "SELECT 1 FROM files WHERE approved=0 OR active=1 LIMIT 1",
                    &[],
                )?
                .is_some()
            {
                self.set_state(
                    "pending",
                    Some("Some personal files are waiting for approval or remain active and local until completed."),
                )?;
            }
        }
        self.status()
    }

    fn upload_approved(&self) -> Result<()> {
        let destination = self.validate_destination()?;
        let repository_id = destination
            .get("repository_id")
            .map(Value::py_str)
            .unwrap_or_default();
        let rows = self.db.rows(
            "SELECT v.*,f.logical_path FROM versions v JOIN files f USING(artifact_id)
                    WHERE f.approved=1 AND f.active=0 AND (v.remote_repo IS NULL OR v.remote_repo!=?) ORDER BY v.accessed",
            &[text(repository_id.as_str())],
        )?;
        for row in rows {
            let path = match row
                .get("local_path")
                .and_then(Value::as_str)
                .filter(|local| !local.is_empty())
            {
                Some(local) => Some(self.cache_path(local)?),
                None => None,
            };
            let Some(path) = path.filter(|path| is_file(path)) else {
                return Err(storage_error(
                    "conflict",
                    "An unsynchronized local revision is missing. Restore it before cleanup.",
                ));
            };
            let content = fs::read(&path)?;
            let sha = row.string("sha256");
            if sha256::hex_digest(&content) != sha {
                return Err(storage_error(
                    "conflict",
                    "A local file changed outside Relay. Import the edited file before synchronization.",
                ));
            }
            let artifact_id = row.string("artifact_id");
            let remote_path = format!(
                "files/{artifact_id}/{sha}{}",
                suffix(&row.string("logical_path"))
            );
            // Each revision owns a unique immutable path. A conflicting byte
            // sequence cannot overwrite it.
            let commit = self.github.publish(
                &destination.string("full_name"),
                &destination.string("branch"),
                &[(remote_path.clone(), content.clone())],
                &[(remote_path, None)],
            )?;
            self.db.execute(
                "UPDATE versions SET remote_repo=?,remote_commit=?,remote_blob=? WHERE artifact_id=? AND sha256=?",
                &[
                    text(repository_id.as_str()),
                    text(commit),
                    text(git_blob_id(&content)),
                    text(artifact_id),
                    text(sha),
                ],
            )?;
            self.db.commit()?;
        }
        self.publish_catalog(&destination)
    }

    /// `_verify_remote(reference, destination)`: the immutable remote copy of
    /// one version, checked against its proofs.
    pub fn verify_remote(&self, reference: &Dict, destination: &Dict) -> Result<Vec<u8>> {
        let repository_id = destination.get("repository_id").map(Value::py_str);
        if reference.get("remote_repo").and_then(Value::as_str) != repository_id.as_deref() {
            return Err(storage_error(
                "conflict",
                "This revision belongs to another storage destination.",
            ));
        }
        let path = format!(
            "files/{}/{}{}",
            reference.string("artifact_id"),
            reference.string("sha256"),
            suffix(&reference.string("logical_path"))
        );
        let full_name = destination.string("full_name");
        let remote_commit = reference
            .get("remote_commit")
            .map(Value::py_str)
            .unwrap_or_default();
        let tree = self.github.tree(&full_name, &remote_commit)?;
        let remote_blob = reference.get("remote_blob").cloned().unwrap_or(Value::Null);
        if !json::py_eq_optional(tree.get(&path), Some(&remote_blob)) {
            return Err(storage_error(
                "conflict",
                "The immutable remote revision no longer matches the catalog.",
            ));
        }
        let size = reference.get("size").and_then(Value::py_int);
        let content = self
            .github
            .read_blob(&full_name, &remote_blob.py_str(), size)?;
        if sha256::hex_digest(&content) != reference.string("sha256") {
            return Err(storage_error(
                "conflict",
                "The remote checksum failed; local content is preserved.",
            ));
        }
        Ok(content)
    }

    /// `read(artifact_id, sha256)`: a version's bytes, from the cache or
    /// streamed back from GitHub into it.
    pub fn read(&self, artifact_id: &str, sha256: Option<&str>) -> Result<Vec<u8>> {
        let _guard = self.lock.lock();
        let reference = self.reference(artifact_id, sha256)?;
        let digest = reference.string("sha256");
        let local = reference
            .get("local_path")
            .and_then(Value::as_str)
            .filter(|local| !local.is_empty());
        let cached = match local {
            Some(local) => Some(self.cache_path(local)?),
            None => None,
        };
        let content = match cached.filter(|path| is_file(path)) {
            Some(path) => {
                let content = fs::read(&path)?;
                if sha256::hex_digest(&content) != digest {
                    return Err(storage_error(
                        "conflict",
                        "The local checksum failed. No content was overwritten.",
                    ));
                }
                content
            }
            None => {
                let content = match self
                    .validate_destination()
                    .and_then(|destination| self.verify_remote(&reference, &destination))
                {
                    Ok(content) => content,
                    Err(error) => {
                        if error.class == "StorageError" {
                            self.set_state(
                                error.state.as_deref().unwrap_or_default(),
                                Some(&error.message),
                            )?;
                        }
                        return Err(error);
                    }
                };
                // A single verified result goes from memory into an atomic
                // file: no clone, unpacked history or download directory.
                let path = self
                    .files_root
                    .join(reference.string("category"))
                    .join(artifact_id)
                    .join(format!(
                        "{digest}{}",
                        suffix(&reference.string("logical_path"))
                    ));
                self.cache_path(&relative(&path, &self.root))?;
                fs::create_dir_all(path.parent().expect("cache parent"))?;
                let temporary = write_temporary(&path, &content)?;
                let placed = fs::rename(&temporary, &path)
                    .map_err(Error::from)
                    .and_then(|()| self.durable_directory(path.parent().expect("cache parent")))
                    .and_then(|()| {
                        self.db.execute(
                            "UPDATE versions SET local_path=? WHERE artifact_id=? AND sha256=?",
                            &[
                                text(relative(&path, &self.root)),
                                text(artifact_id),
                                text(digest.as_str()),
                            ],
                        )
                    });
                let _ = fs::remove_file(&temporary);
                placed?;
                content
            }
        };
        self.db.execute(
            "UPDATE versions SET accessed=? WHERE artifact_id=? AND sha256=?",
            &[real(self.clock()), text(artifact_id), text(digest.as_str())],
        )?;
        self.restore_source(artifact_id, &digest, &content)?;
        self.db.commit()?;
        Ok(content)
    }

    /// `policy(budget_bytes=..., retention_days=...)`.
    pub fn policy(&self, budget_bytes: &Value, retention_days: &Value) -> Result<Dict> {
        let Value::Int(budget) = budget_bytes else {
            return Err(Error::value("Storage budget must be a positive byte count"));
        };
        if *budget <= 0 {
            return Err(Error::value("Storage budget must be a positive byte count"));
        }
        let Value::Int(days) = retention_days else {
            return Err(Error::value("Retention days must be a nonnegative integer"));
        };
        if *days < 0 {
            return Err(Error::value("Retention days must be a nonnegative integer"));
        }
        {
            let _guard = self.lock.lock();
            self.set("budget_bytes", budget_bytes)?;
            self.set("retention_days", retention_days)?;
            self.db.commit()?;
        }
        self.enforce_retention()
    }

    /// `usage()`: bytes under the storage roots.
    pub fn usage(&self) -> Result<Dict> {
        let roots = [
            self.files_root.clone(),
            self.support_root.clone(),
            self.root.join("notes"),
            self.general_tasks_root.clone(),
        ];
        let (mut total, mut git_bytes, mut user_file_bytes) = (0i64, 0i64, 0i64);
        for root in &roots {
            if is_symlink(root) || !root.exists() {
                continue;
            }
            walk(root, &mut |directory, dirs, files| {
                dirs.retain(|name| !is_symlink(&directory.join(name)));
                for name in files {
                    let path = directory.join(name);
                    if is_symlink(&path) {
                        continue;
                    }
                    let size = fs::metadata(&path)?.len() as i64;
                    total += size;
                    let relative_path = relative(&path, root);
                    let parts: Vec<&str> = relative_path.split('/').collect();
                    if *root == self.files_root
                        || (*root == self.general_tasks_root
                            && !parts.iter().any(|part| part.starts_with('.')))
                    {
                        user_file_bytes += size;
                    }
                    if parts.contains(&".git") {
                        git_bytes += size;
                    }
                }
                Ok(())
            })?;
        }
        let mut usage = Dict::new();
        usage.insert("total_bytes", total);
        usage.insert("git_object_bytes", git_bytes);
        usage.insert("user_file_bytes", user_file_bytes);
        Ok(usage)
    }

    fn total_bytes(&self) -> Result<i64> {
        Ok(self
            .usage()?
            .get("total_bytes")
            .and_then(Value::py_int)
            .unwrap_or(0))
    }

    /// `enforce_retention()`: evict verified, synchronized cache copies past
    /// the retention window or over the budget.
    pub fn enforce_retention(&self) -> Result<Dict> {
        self.discover_documents()?;
        let _guard = self.lock.lock();
        let budget = self
            .get("budget_bytes", Value::Int(DEFAULT_BUDGET_BYTES))?
            .py_float()
            .unwrap_or(0.0);
        let days = self
            .get("retention_days", Value::Int(DEFAULT_RETENTION_DAYS))?
            .py_float()
            .unwrap_or(0.0);
        let cutoff = self.clock() - days * 86400.0;
        let mut reclaimed = 0i64;
        let candidates = self.db.rows(
            "SELECT v.*,f.logical_path,f.current_sha FROM versions v JOIN files f USING(artifact_id)
                WHERE v.local_path IS NOT NULL AND f.pinned=0 AND f.active=0 AND v.remote_commit IS NOT NULL
                ORDER BY v.accessed",
            &[],
        )?;
        let mut destination: Option<Dict> = None;
        for row in candidates {
            let accessed = row.get("accessed").and_then(Value::py_float).unwrap_or(0.0);
            if accessed >= cutoff && (self.total_bytes()? as f64) <= budget {
                continue;
            }
            let verified = match &destination {
                Some(destination) => self.verify_remote(&row, destination).map(|_| ()),
                None => self.validate_destination().and_then(|found| {
                    let result = self.verify_remote(&row, &found).map(|_| ());
                    destination = Some(found);
                    result
                }),
            };
            if let Err(error) = verified {
                if error.class == "StorageError" {
                    self.set_state(
                        error.state.as_deref().unwrap_or_default(),
                        Some(&error.message),
                    )?;
                    break;
                }
                return Err(error);
            }
            let path = self.cache_path(&row.string("local_path"))?;
            let sha = row.string("sha256");
            // Verify again immediately before unlink; an external edit is
            // unique local work.
            if is_file(&path) && sha256::hex_digest(&fs::read(&path)?) == sha {
                let artifact_id = row.string("artifact_id");
                if let Some(source) = self.source_path(&artifact_id)?
                    && !source.starts_with(&self.general_tasks_root)
                    && sha == row.string("current_sha")
                    && is_file(&source)
                    && sha256::hex_digest(&fs::read(&source)?) == sha
                {
                    reclaimed += fs::metadata(&source)?.len() as i64;
                    fs::remove_file(&source)?;
                }
                reclaimed += fs::metadata(&path)?.len() as i64;
                fs::remove_file(&path)?;
                self.db.execute(
                    "UPDATE versions SET local_path=NULL WHERE artifact_id=? AND sha256=?",
                    &[text(artifact_id), text(sha)],
                )?;
                self.db.commit()?;
            }
        }
        self.db.raw("PRAGMA wal_checkpoint(TRUNCATE)")?;
        let mut result = self.status()?;
        result.insert("reclaimed_bytes", reclaimed);
        Ok(result)
    }

    /// `status()`: the state, destination, usage and policy.
    pub fn status(&self) -> Result<Dict> {
        let _guard = self.lock.lock();
        let destination = self.get("destination", Value::Null)?;
        let usage = self.usage()?;
        let budget = self.get("budget_bytes", Value::Int(DEFAULT_BUDGET_BYTES))?;
        let (mut evictable, mut protected, mut unsynced) = (0i64, 0i64, 0i64);
        let rows = self.db.rows(
            "SELECT v.*,f.pinned,f.active,f.current_sha FROM versions v JOIN files f USING(artifact_id) WHERE v.local_path IS NOT NULL OR v.sha256=f.current_sha",
            &[],
        )?;
        for row in rows {
            #[derive(Clone, Copy)]
            enum Bucket {
                Evictable,
                Protected,
                Unsynced,
            }
            let bucket = if row.get("pinned").is_some_and(Value::truthy)
                || row.get("active").is_some_and(Value::truthy)
            {
                Bucket::Protected
            } else if !row.get("remote_commit").is_some_and(Value::truthy) {
                Bucket::Unsynced
            } else {
                Bucket::Evictable
            };
            let measured = (|| -> Result<Vec<(Bucket, i64)>> {
                let mut sizes = Vec::new();
                let path = match row
                    .get("local_path")
                    .and_then(Value::as_str)
                    .filter(|local| !local.is_empty())
                {
                    Some(local) => Some(self.cache_path(local)?),
                    None => None,
                };
                let cached = match &path {
                    Some(path) if is_file(path) => fs::metadata(path)?.len() as i64,
                    _ => 0,
                };
                sizes.push((bucket, cached));
                let source = if row.string("sha256") == row.string("current_sha") {
                    self.source_path(&row.string("artifact_id"))?
                } else {
                    None
                };
                if let Some(source) = source
                    && Some(&source) != path.as_ref()
                    && is_file(&source)
                {
                    let source_bucket = if source.starts_with(&self.general_tasks_root) {
                        Bucket::Protected
                    } else {
                        bucket
                    };
                    sizes.push((source_bucket, fs::metadata(&source)?.len() as i64));
                }
                Ok(sizes)
            })();
            // Python adds the cache copy before it measures the source.
            let sizes = match measured {
                Ok(sizes) => sizes,
                Err(error) if matches!(error.class, "StorageError" | "OSError") => continue,
                Err(error) => return Err(error),
            };
            for (bucket, size) in sizes {
                match bucket {
                    Bucket::Evictable => evictable += size,
                    Bucket::Protected => protected += size,
                    Bucket::Unsynced => unsynced += size,
                }
            }
        }
        let number = |key: &str| usage.get(key).and_then(Value::py_int).unwrap_or(0);
        let total = number("total_bytes");
        let git_bytes = number("git_object_bytes");
        let managed = evictable + protected + unsynced;
        let unmanaged = (number("user_file_bytes") - managed).max(0);
        unsynced += unmanaged;
        let over_budget = budget
            .py_float()
            .is_some_and(|budget| (total as f64) > budget);
        let mut reasons = Vec::new();
        if over_budget {
            if unsynced != 0 {
                reasons.push("Unsynchronized files are preserved. Connect or retry GitHub, or explicitly export/delete files.");
            }
            if unmanaged != 0 {
                reasons.push("Unregistered task files and operational traces remain local. Export or delete them explicitly; traces are never uploaded.");
            }
            if protected != 0 {
                reasons.push("Pinned files and active tasks or recordings are protected.");
            }
            if git_bytes != 0 {
                reasons.push("Local Git history is protected; verified legacy notes archives can be migrated separately.");
            }
            reasons.push(
                "The durable catalog and other required local metadata count toward storage usage.",
            );
        }
        let mut usage = usage.clone();
        usage.insert("evictable_bytes", evictable);
        usage.insert("protected_bytes", protected);
        usage.insert("unsynced_bytes", unsynced);
        usage.insert("unmanaged_bytes", unmanaged);
        usage.insert(
            "metadata_bytes",
            (total - (evictable + protected + unsynced) - git_bytes).max(0),
        );
        let mut status = Dict::new();
        status.insert("state", self.get("state", Value::Str("local_only".into()))?);
        status.insert("message", self.get("message", Value::Null)?);
        status.insert(
            "connected",
            self.get("connected", Value::Bool(false))?.truthy(),
        );
        status.insert("destination", destination);
        status.insert("files_root", self.files_root.to_string_lossy().into_owned());
        status.insert("budget_bytes", budget);
        status.insert(
            "retention_days",
            self.get("retention_days", Value::Int(DEFAULT_RETENTION_DAYS))?,
        );
        status.insert("usage", usage);
        status.insert("over_budget", over_budget);
        status.insert(
            "overage_reasons",
            Value::List(reasons.into_iter().map(Value::from).collect()),
        );
        status.insert("disclosure", DISCLOSURE);
        Ok(status)
    }
}

/// `re.search(r"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b", output)`.
fn device_code(output: &str) -> Option<String> {
    let characters: Vec<char> = output.chars().collect();
    let word = |c: char| c.is_alphanumeric() || c == '_';
    let code = |c: char| c.is_ascii_uppercase() || c.is_ascii_digit();
    (0..characters.len().saturating_sub(8)).find_map(|start| {
        let window = &characters[start..start + 9];
        let shaped = window[..4].iter().all(|c| code(*c))
            && window[4] == '-'
            && window[5..].iter().all(|c| code(*c));
        let before = start == 0 || !word(characters[start - 1]);
        let after = characters.get(start + 9).is_none_or(|c| !word(*c));
        (shaped && before && after).then(|| window.iter().collect())
    })
}

/// `re.fullmatch(r"[0-9a-f]{64}(?:\.[^/]+)?", name)`: an immutable cache name.
fn is_cache_name(name: &str) -> bool {
    name.len() >= 64
        && is_hex(&name[..64], 64)
        && (name.len() == 64
            || (name[64..].starts_with('.') && name.len() > 65 && !name[65..].contains('/')))
}

fn parse_json_bytes(content: &[u8]) -> Result<Value> {
    std::str::from_utf8(content)
        .ok()
        .and_then(json::parse)
        .ok_or_else(|| Error::value("Expecting value"))
}

/// `_logical_path(path, category)`: an explicitly selectable personal file
/// path, normalised as `PurePosixPath` prints it.
pub fn logical_path(path: &str, category: &str) -> Result<String> {
    let absolute = path.starts_with('/');
    let parts: Vec<&str> = path
        .split('/')
        .filter(|part| !part.is_empty() && *part != ".")
        .collect();
    if !["notes", "tasks", "documents", "history"].contains(&category)
        || absolute
        || parts.contains(&"..")
    {
        return Err(Error::value(
            "Only explicitly selected personal notes, task files and documents can be stored",
        ));
    }
    if parts.first() != Some(&category) || parts.iter().any(|part| part.starts_with('.')) {
        return Err(Error::value(
            "Private runtime files and hidden paths cannot be synchronized",
        ));
    }
    let normalized = parts.join("/");
    if [".sqlite", ".sqlite3", ".db", ".log", ".pem", ".key"]
        .contains(&suffix(&normalized).to_lowercase().as_str())
    {
        return Err(Error::value(
            "Operational databases, logs and credential files cannot be synchronized",
        ));
    }
    Ok(normalized)
}

/// `handle_personal_storage_request`: the daemon route adapter. `None` for
/// a route outside `/v1/personal-storage/`; otherwise the response body or
/// the error the route maps (`StorageError` 409, `ValueError` 400).
pub fn handle_personal_storage_request(
    storage: &PersonalFileStorage,
    method: &str,
    path: &str,
    payload: Option<&Dict>,
) -> Option<Result<Dict>> {
    if !path.starts_with("/v1/personal-storage/") {
        return None;
    }
    let empty = Dict::new();
    let payload = payload.unwrap_or(&empty);
    let route = path
        .split('?')
        .next()
        .unwrap_or_default()
        .strip_prefix("/v1/personal-storage/")
        .unwrap_or_default();
    let string_list = |value: Option<&Value>| -> Option<Vec<String>> {
        value
            .filter(|value| !matches!(value, Value::Null))
            .map(|value| {
                value
                    .as_list()
                    .unwrap_or_default()
                    .iter()
                    .map(Value::py_str)
                    .collect()
            })
    };
    let artifact_id = || {
        payload
            .get("artifact_id")
            .map(Value::py_str)
            .ok_or_else(|| key_error("artifact_id"))
    };
    Some(match (method, route) {
        ("GET", "status") => storage.status(),
        ("GET", "account") => storage.account(),
        ("GET", "files") => {
            storage.list_files(&payload.get("query").map(Value::py_str).unwrap_or_default())
        }
        ("POST", "sign-in") => storage.sign_in(),
        ("POST", "configure") => storage.configure(
            payload.get("confirm").unwrap_or(&Value::Null),
            payload.present("repository_name").and_then(Value::as_str),
            payload.get("create").is_none_or(Value::truthy),
        ),
        ("POST", "disconnect") => storage.disconnect(),
        ("POST", "sync") => {
            let ids = string_list(payload.get("artifact_ids"));
            storage.sync(
                payload.get("approve").unwrap_or(&Value::Bool(false)),
                ids.as_deref(),
            )
        }
        ("POST", "policy") => storage.policy(
            payload
                .get("budget_bytes")
                .unwrap_or(&Value::Int(DEFAULT_BUDGET_BYTES)),
            payload
                .get("retention_days")
                .unwrap_or(&Value::Int(DEFAULT_RETENTION_DAYS)),
        ),
        ("POST", "pin") => artifact_id()
            .and_then(|id| storage.pin(&id, payload.get("pinned").is_none_or(Value::truthy))),
        ("POST", "retrieve") => artifact_id().and_then(|id| {
            let sha = payload.present("sha256").map(Value::py_str);
            let content = storage.read(&id, sha.as_deref())?;
            let mut result = Dict::new();
            result.insert("reference", storage.reference(&id, sha.as_deref())?);
            result.insert("content_base64", b64encode(&content));
            Ok(result)
        }),
        _ => Err(Error::value("Unsupported personal storage route")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn logical_paths_follow_the_allowlist() {
        assert_eq!(
            logical_path("documents/./a//b.txt", "documents").unwrap(),
            "documents/a/b.txt"
        );
        assert_eq!(
            logical_path("/documents/a", "documents")
                .unwrap_err()
                .message,
            "Only explicitly selected personal notes, task files and documents can be stored"
        );
        assert_eq!(
            logical_path("documents/.git/x", "documents")
                .unwrap_err()
                .message,
            "Private runtime files and hidden paths cannot be synchronized"
        );
        assert_eq!(
            logical_path("documents/x.DB", "documents")
                .unwrap_err()
                .message,
            "Operational databases, logs and credential files cannot be synchronized"
        );
    }

    #[test]
    fn helpers_match_python() {
        assert_eq!(quote("feature/a b"), "feature%2Fa%20b");
        assert_eq!(suffix("notes/RR-N1.md"), ".md");
        assert_eq!(suffix("notes/.hidden"), "");
        assert_eq!(
            device_code("code: ABCD-12EF now"),
            Some("ABCD-12EF".to_string())
        );
        assert_eq!(device_code("xABCD-12EF"), None);
        assert!(is_cache_name(&format!("{}.md", "a".repeat(64))));
        assert!(!is_cache_name(&format!("{}.", "a".repeat(64))));
    }
}
