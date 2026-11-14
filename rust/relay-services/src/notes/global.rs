//! `services/global_notes.py`: local, project-independent notes with a
//! resumable import of legacy project catalogs.
//!
//! Until the user migrates notes into personal storage, the library is the
//! `global-notes` artifact store in `<state root>/notes`; afterwards it is
//! the personal-file cache. Either way the routes reach one
//! [`NoteManager`].

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use relay_artifacts::store::{ArtifactStore, Mutation, Operation, StoreOptions};
use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256;

use super::NoteManager;
use super::contract::{decode_note_index, parse_note_document};
use super::personal::{PersonalNoteManager, PersonalNotes};
use super::project::ProjectNoteManager;
use super::util;
use crate::personal_storage::{PersonalFileStorage, ReentrantLock};
use crate::{Error, Result};

const IMPORT_INTERVAL: Duration = Duration::from_secs(30);
const INDEX_PATH: &str = ".orchestrator/note-index.jsonl";
const CONFIG_PATH: &str = ".orchestrator/config.toml";

/// `sources()`: each registered project's note manager, by repository path.
pub type NoteSources = Box<dyn Fn() -> Vec<(String, Arc<dyn NoteManager>)> + Send + Sync>;

#[derive(Clone)]
enum Manager {
    Project(Arc<ProjectNoteManager>),
    Personal(Arc<PersonalNoteManager>),
}

impl Manager {
    fn shared(&self) -> Arc<dyn NoteManager> {
        match self {
            Manager::Project(manager) => manager.clone(),
            Manager::Personal(manager) => manager.clone(),
        }
    }
}

fn guard<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// `subprocess.run(arguments, check=True, capture_output=True, timeout=...)`
/// for git; a failure is `CalledProcessError`, as `sync` expects.
fn git(arguments: &[&str], timeout: Duration) -> Result<String> {
    let mut child = Command::new("git")
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait()? {
            let mut stdout = String::new();
            if let Some(mut pipe) = child.stdout.take() {
                use std::io::Read;
                let _ = pipe.read_to_string(&mut stdout);
            }
            if !status.success() {
                return Err(Error::new(
                    "CalledProcessError",
                    format!(
                        "Command {:?} returned non-zero exit status {}.",
                        arguments,
                        status.code().unwrap_or(-1)
                    ),
                ));
            }
            return Ok(stdout);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Error::new(
                "TimeoutExpired",
                format!("Command {arguments:?} timed out"),
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn is_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink())
}

fn only_artifact_files(repo: &Path) -> Result<bool> {
    for entry in fs::read_dir(repo)? {
        let name = entry?.file_name();
        if name != ".git" && name != ".orchestrator" {
            return Ok(false);
        }
    }
    Ok(true)
}

/// `GlobalNoteLibrary(state_root, device_id, sources)`.
pub struct GlobalNoteLibrary {
    pub root: PathBuf,
    pub device_id: String,
    sources: NoteSources,
    lock: ReentrantLock,
    manager: Mutex<Option<Manager>>,
    last_import: Mutex<Option<Instant>>,
    source_heads: Mutex<HashMap<String, String>>,
    personal_storage: Mutex<Option<Arc<PersonalFileStorage>>>,
}

impl GlobalNoteLibrary {
    pub fn new(state_root: &Path, device_id: &str, sources: NoteSources) -> Self {
        Self {
            root: state_root.to_path_buf(),
            device_id: device_id.to_string(),
            sources,
            lock: ReentrantLock::default(),
            manager: Mutex::new(None),
            last_import: Mutex::new(None),
            source_heads: Mutex::new(HashMap::new()),
            personal_storage: Mutex::new(None),
        }
    }

    pub(crate) fn set_personal_storage(&self, storage: Arc<PersonalFileStorage>) {
        *guard(&self.personal_storage) = Some(storage);
    }

    /// `library._manager = None`: the next use reopens the writer.
    pub(crate) fn reset_manager(&self) {
        *guard(&self.manager) = None;
    }

    fn storage(&self) -> Option<Arc<PersonalFileStorage>> {
        guard(&self.personal_storage).clone()
    }

    fn migrated(storage: &PersonalFileStorage) -> Result<bool> {
        Ok(storage.get("notes_migrated", Value::Bool(false))?.truthy())
    }

    fn current(&self) -> Result<Manager> {
        let _lock = self.lock.lock();
        if let Some(manager) = guard(&self.manager).clone() {
            return Ok(manager);
        }
        if let Some(storage) = self.storage()
            && Self::migrated(&storage)?
        {
            let manager = Manager::Personal(Arc::new(PersonalNoteManager::new(
                storage,
                &self.device_id,
            )?));
            *guard(&self.manager) = Some(manager.clone());
            return Ok(manager);
        }
        let repo = self.root.join("notes");
        fs::create_dir_all(&repo)?;
        if !repo.join(".git").exists() {
            git(
                &["init", "--quiet", &repo.to_string_lossy()],
                Duration::from_secs(10),
            )?;
        }
        let store = ArtifactStore::open(
            &repo,
            "global-notes",
            &self.root,
            StoreOptions {
                enabled: true,
                ..StoreOptions::default()
            },
        )?;
        store.initialize(&self.device_id, "system")?;
        let snapshot = store.snapshot()?;
        let config = snapshot.file(CONFIG_PATH).unwrap_or_default().to_vec();
        let old = b"prefix = \"NOT\"";
        if let Some(position) = config.windows(old.len()).position(|window| window == old) {
            let mut content = config[..position].to_vec();
            content.extend_from_slice(b"prefix = \"RR\"");
            // `bytes.replace` replaces every occurrence.
            let rest = String::from_utf8_lossy(&config[position + old.len()..])
                .replace("prefix = \"NOT\"", "prefix = \"RR\"");
            content.extend_from_slice(rest.as_bytes());
            let mut mutation = Mutation::new(
                "global-notes-config",
                "system",
                &self.device_id,
                vec![Operation::ConfigWrite { content }],
            );
            mutation.expected_base = Some(snapshot.commit_id.clone());
            mutation.summary = "Configure global notes".to_string();
            store.mutate(&mutation)?;
        }
        let manager = Arc::new(ProjectNoteManager::new(Arc::new(store), &self.device_id));
        manager.ensure_global_codes()?;
        let manager = Manager::Project(manager);
        *guard(&self.manager) = Some(manager.clone());
        Ok(manager)
    }

    /// `manager`: the library's note manager, opened on first use.
    pub fn manager(&self) -> Result<Arc<dyn NoteManager>> {
        Ok(self.current()?.shared())
    }

    /// `prepare_personal_storage(storage)`: stage notes and their old Git
    /// history for an explicit sync. Uploads and removes nothing; a
    /// recording or paused note postpones the migration so the recorder
    /// never changes writers mid-capture.
    pub fn prepare_personal_storage(&self, storage: &PersonalFileStorage) -> Result<()> {
        let _lock = self.lock.lock();
        if Self::migrated(storage)? {
            return Ok(());
        }
        let Manager::Project(manager) = self.current()? else {
            return Ok(());
        };
        manager.store.with_writer_lock(|| {
            Ok((|| -> Result<()> {
                let snapshot = manager.store.snapshot()?;
                let catalog = decode_note_index(
                    snapshot.file(INDEX_PATH).unwrap_or_default(),
                    "global-notes",
                )?;
                if catalog.iter().any(|(_, row)| {
                    !row.get("recording_state")
                        .is_some_and(|state| state.is_str("completed"))
                }) {
                    return Ok(());
                }
                let candidate = PersonalNotes::open(storage, &self.device_id, true)?;
                let ids: Vec<String> = catalog.iter().map(|(id, _)| id.clone()).collect();
                candidate.import_git_events(&manager, &ids)?;
                for (_, entry) in &catalog {
                    let source = manager.get(&entry.string("artifact_id"))?;
                    let markdown = util::b64decode(&source.string("markdown_base64"))
                        .ok_or_else(|| Error::value("Incorrect padding"))?;
                    candidate.import_catalog_entry(entry, &parse_note_document(&markdown)?)?;
                }
                // The exact old graph is archived before any .git data is
                // reclaimed. A bundle holds only objects and refs, never Git
                // credentials or config.
                let bundle = storage
                    .support_root
                    .join(format!("notes-history-{}.bundle", util::uuid4_hex()));
                let repo = manager.store.repo_path.to_string_lossy().into_owned();
                let bundle_text = bundle.to_string_lossy().into_owned();
                let archived = (|| -> Result<()> {
                    git(
                        &["-C", &repo, "bundle", "create", &bundle_text, "--all"],
                        Duration::from_secs(120),
                    )?;
                    git(
                        &["-C", &repo, "bundle", "verify", &bundle_text],
                        Duration::from_secs(120),
                    )?;
                    let mut metadata = Dict::new();
                    metadata.insert("legacy_note_head", snapshot.commit_id.as_str());
                    storage.put(
                        "legacy-global-notes-history",
                        "history/global-notes.bundle",
                        &fs::read(&bundle)?,
                        "history",
                        Some(&Value::Dict(metadata)),
                        false,
                        None,
                        true,
                    )?;
                    Ok(())
                })();
                let _ = fs::remove_file(&bundle);
                archived?;
                storage.set(
                    "notes_migration_head",
                    &Value::Str(snapshot.commit_id.clone()),
                )?;
                let config =
                    String::from_utf8_lossy(snapshot.file(CONFIG_PATH).unwrap_or_default())
                        .into_owned();
                let configured = if config.contains("next_note_id") {
                    configured_next_note_id(&config).ok_or_else(|| {
                        Error::new("TypeError", "'NoneType' object is not subscriptable")
                    })?
                } else {
                    1
                };
                storage.set(
                    "next_personal_note_id",
                    &Value::Int(candidate.next_number()?.max(configured)),
                )?;
                storage.db.commit()
            })())
        })?
    }

    /// `finalize_personal_storage(storage)`: switch writers only after every
    /// migrated version and the history bundle have remote proof.
    pub fn finalize_personal_storage(&self, storage: &PersonalFileStorage) -> Result<()> {
        let _lock = self.lock.lock();
        let notes_root = self.root.join("notes");
        if Self::migrated(storage)? {
            let pending = storage.get("notes_migration_cleanup", Value::Null)?;
            if let Some(pending) = pending.as_str().filter(|pending| !pending.is_empty()) {
                let repo = PathBuf::from(pending);
                if repo.exists() {
                    if resolve(&repo) != resolve(&notes_root) || is_symlink(&repo) {
                        return Err(Error::value(
                            "Unexpected legacy notes cleanup location; content preserved",
                        ));
                    }
                    let _storage_lock = storage.lock.lock();
                    let reference = storage.reference("legacy-global-notes-history", None)?;
                    let destination = storage.validate_destination()?;
                    storage.verify_remote(&reference, &destination)?;
                    let head = git(
                        &["-C", pending, "rev-parse", "refs/heads/relay/artifacts"],
                        Duration::from_secs(10),
                    )?;
                    if !storage
                        .get("notes_migration_head", Value::Null)?
                        .is_str(json::py_strip(&head))
                    {
                        return Err(Error::value(
                            "Legacy notes changed since archival; content preserved",
                        ));
                    }
                    if !only_artifact_files(&repo)? {
                        return Err(Error::value(
                            "Legacy notes folder contains other files; content preserved",
                        ));
                    }
                    fs::remove_dir_all(&repo)?;
                }
                storage.set("notes_migration_cleanup", &Value::Null)?;
                storage.db.commit()?;
            }
            return Ok(());
        }
        let expected = storage.get("notes_migration_head", Value::Null)?;
        if !expected.truthy() || !storage.get("connected", Value::Null)?.truthy() {
            return Ok(());
        }
        let Manager::Project(manager) = self.current()? else {
            return Ok(());
        };
        manager.store.with_writer_lock(|| {
            Ok((|| -> Result<()> {
                if !manager.store.head()?.is_some_and(|head| expected.is_str(&head)) {
                    return Ok(());
                }
                let rows = storage.db.rows(
                    "SELECT artifact_id,sha256 FROM versions v JOIN files f USING(artifact_id) WHERE f.category IN ('notes','history')",
                    &[],
                )?;
                let destination = storage.validate_destination()?;
                for row in rows {
                    let reference = storage.reference(&row.string("artifact_id"), Some(&row.string("sha256")))?;
                    if !reference.get("remote_commit").is_some_and(Value::truthy) {
                        return Ok(());
                    }
                    storage.verify_remote(&reference, &destination)?;
                }
                let repo = manager.store.repo_path.clone();
                if repo != resolve(&notes_root) || is_symlink(&repo) {
                    return Err(Error::value(
                        "Unexpected legacy notes repository location; history preserved",
                    ));
                }
                if !only_artifact_files(&repo)? {
                    return Err(Error::value(
                        "Legacy notes folder contains other files; history preserved",
                    ));
                }
                // Record the writer transition durably first: a crash now
                // leaves a harmless protected old folder, never an empty
                // notes library.
                storage.set("notes_migrated", &Value::Bool(true))?;
                storage.set(
                    "notes_migration_cleanup",
                    &Value::Str(repo.to_string_lossy().into_owned()),
                )?;
                storage.db.commit()?;
                let personal: Arc<PersonalFileStorage> = self
                    .storage()
                    .ok_or_else(|| Error::runtime("personal storage is not attached"))?;
                *guard(&self.manager) = Some(Manager::Personal(Arc::new(PersonalNoteManager::new(
                    personal,
                    &self.device_id,
                )?)));
                fs::remove_dir_all(&repo)?;
                storage.set("notes_migration_cleanup", &Value::Null)?;
                storage.db.commit()
            })())
        })?
    }

    /// `import_legacy()`: copy saved notes from registered projects at most
    /// every 30 seconds. One unreadable note or offline source hides nothing
    /// else.
    pub fn import_legacy(&self) -> Result<()> {
        let _lock = self.lock.lock();
        if guard(&self.last_import).is_some_and(|last| last.elapsed() < IMPORT_INTERVAL) {
            return Ok(());
        }
        let manager = self.manager()?;
        let completed: Vec<String> = all_cards(manager.as_ref())?
            .into_iter()
            .filter(|card| {
                card.get("recording_state")
                    .is_some_and(|state| state.is_str("completed"))
            })
            .map(|card| card.string("artifact_id"))
            .collect();
        for (repo_path, source) in (self.sources)() {
            let _ = (|| -> Result<()> {
                let head = source.head()?;
                if let Some(head) = &head
                    && guard(&self.source_heads).get(&repo_path) == Some(head)
                {
                    return Ok(());
                }
                let mut imported_all = true;
                for card in all_cards(source.as_ref())? {
                    let artifact_id = card.string("artifact_id");
                    if completed.contains(&artifact_id) {
                        continue;
                    }
                    let imported = source.get(&artifact_id).and_then(|response| {
                        let note = response
                            .get("note")
                            .and_then(Value::as_dict)
                            .cloned()
                            .unwrap_or_default();
                        manager.import_saved_note(&note, Some(&repo_path))
                    });
                    if imported.is_err() {
                        imported_all = false;
                    }
                }
                if imported_all && let Some(head) = head {
                    guard(&self.source_heads).insert(repo_path.clone(), head);
                }
                Ok(())
            })();
        }
        *guard(&self.last_import) = Some(Instant::now());
        Ok(())
    }

    /// `list(limit=..., after=...)`: every global note, newest first, paged
    /// by an opaque cursor bound to the catalog's digest.
    pub fn list(&self, limit: i64, after: Option<&str>) -> Result<Dict> {
        let limit = limit.clamp(1, 100);
        self.import_legacy()?;
        let (mut cards, sync) = {
            let _lock = self.lock.lock();
            let repository = resolve(&self.root.join("notes"))
                .to_string_lossy()
                .into_owned();
            let cards: Vec<Dict> = all_cards(self.manager()?.as_ref())?
                .into_iter()
                .map(|mut card| {
                    card.insert("repository_path", repository.as_str());
                    card
                })
                .collect();
            let mut sync = Dict::new();
            sync.insert("mode", "local_only");
            sync.insert("state", "local_only");
            sync.insert("recovery", Value::Null);
            if let Some(storage) = self.storage()
                && Self::migrated(&storage)?
            {
                let state = storage.status()?;
                let connected = state.get("connected").is_some_and(Value::truthy);
                sync.insert("mode", if connected { "enabled" } else { "local_only" });
                sync.insert("state", state.get("state").cloned().unwrap_or(Value::Null));
                sync.insert(
                    "recovery",
                    state.get("message").cloned().unwrap_or(Value::Null),
                );
            }
            (cards, sync)
        };
        cards.sort_by(|a, b| {
            (b.string("created_at"), b.string("artifact_id"))
                .cmp(&(a.string("created_at"), a.string("artifact_id")))
        });
        let cards_value = Value::List(cards.iter().cloned().map(Value::Dict).collect());
        let digest = sha256::hex_digest(json::dumps_sorted(&cards_value).as_bytes());
        let mut offset = 0usize;
        if let Some(after) = after.filter(|after| !after.is_empty()) {
            let invalid = || Error::value("Invalid note cursor");
            let decoded = util::urlsafe_b64decode(after).ok_or_else(invalid)?;
            let cursor = std::str::from_utf8(&decoded)
                .ok()
                .and_then(json::parse)
                .ok_or_else(invalid)?;
            let cursor = cursor.as_dict().ok_or_else(invalid)?;
            let cursor_digest = cursor.get("digest").ok_or_else(invalid)?;
            if !cursor_digest.is_str(&digest) {
                return Err(Error::value(
                    "Notes changed while paging; retry the catalog",
                ));
            }
            let value = cursor
                .get("offset")
                .ok_or_else(invalid)?
                .py_int()
                .ok_or_else(invalid)?;
            if value < 0 || value as usize > cards.len() {
                return Err(invalid());
            }
            offset = value as usize;
        }
        let end = offset + limit as usize;
        let more = end < cards.len();
        let next_cursor = if more {
            let mut cursor = Dict::new();
            cursor.insert("digest", digest.as_str());
            cursor.insert("offset", end as i64);
            Value::Str(util::urlsafe_b64encode(
                json::dumps(&Value::Dict(cursor)).as_bytes(),
            ))
        } else {
            Value::Null
        };
        let total = cards.len();
        let page: Vec<Value> = cards
            .into_iter()
            .skip(offset)
            .take(limit as usize)
            .map(Value::Dict)
            .collect();
        let mut result = Dict::new();
        result.insert("notes", Value::List(page));
        result.insert("artifact_commit", digest);
        result.insert("limit", limit);
        result.insert("has_more", more);
        result.insert("total_count", total as i64);
        result.insert("next_cursor", next_cursor);
        result.insert("sync", sync);
        Ok(result)
    }
}

fn resolve(path: &Path) -> PathBuf {
    PathBuf::from(relay_artifacts::paths::resolve(&path.to_string_lossy()))
}

/// `int(re.search(r"next_note_id\s*=\s*(\d+)", config)[1])`.
fn configured_next_note_id(config: &str) -> Option<i64> {
    let mut rest = config;
    while let Some(index) = rest.find("next_note_id") {
        let after = rest[index + "next_note_id".len()..].trim_start();
        if let Some(value) = after.strip_prefix('=') {
            let digits: String = value
                .trim_start()
                .chars()
                .take_while(char::is_ascii_digit)
                .collect();
            if !digits.is_empty() {
                return digits.parse().ok();
            }
        }
        rest = &rest[index + 1..];
    }
    None
}

/// `_all_cards(manager)`: every page of a manager's catalog.
fn all_cards(manager: &dyn NoteManager) -> Result<Vec<Dict>> {
    let mut cards = Vec::new();
    let mut after: Option<String> = None;
    loop {
        let page = manager.list(100, after.as_deref())?;
        cards.extend(
            page.get("notes")
                .and_then(Value::as_list)
                .unwrap_or_default()
                .iter()
                .filter_map(Value::as_dict)
                .cloned(),
        );
        if !page.get("has_more").is_some_and(Value::truthy) {
            return Ok(cards);
        }
        after = page
            .get("next_cursor")
            .and_then(Value::as_str)
            .map(str::to_string);
    }
}
