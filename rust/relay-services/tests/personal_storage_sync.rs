//! Personal storage against an in-memory GitHub (RR-499): configure a
//! private repository, publish approved files with their proofs, migrate the
//! global notes library into personal storage, evict a synchronized copy and
//! read it back from the remote, as `services/personal_file_storage.py`
//! does. The transport is replaced at `GitHubApi`, the seam Python's tests
//! replace `GitHubFiles` at; nothing reaches the network.

mod common;

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::sync::{Arc, Mutex};

use relay_intents::json::{Dict, Value};
use relay_services::notes::global::GlobalNoteLibrary;
use relay_services::notes::util::{b64decode_strict, b64encode, git_blob_id};
use relay_services::notes::{CreateNote, NoteManager};
use relay_services::personal_storage::{
    GitHubApi, GitHubFiles, PersonalFileStorage, handle_personal_storage_request, storage_error,
};
use relay_services::{Error, Result};

use common::TempRoot;

const DEVICE: &str = "daemon-0123456789abcdef01234567";
const OWNER: &str = "octo";
const REPO: &str = "octo/octo-rr-files";

#[derive(Default)]
struct Remote {
    created: bool,
    description: String,
    blobs: HashMap<String, Vec<u8>>,
    trees: HashMap<String, BTreeMap<String, String>>,
    commits: HashMap<String, String>,
    head: String,
    counter: u64,
    calls: Vec<String>,
}

impl Remote {
    fn id(&mut self) -> String {
        self.counter += 1;
        format!("{:040x}", self.counter)
    }

    fn commit(&mut self, tree: BTreeMap<String, String>) -> String {
        let tree_id = self.id();
        self.trees.insert(tree_id.clone(), tree);
        let commit = self.id();
        self.commits.insert(commit.clone(), tree_id);
        commit
    }
}

#[derive(Clone, Default)]
struct FakeGitHub(Arc<Mutex<Remote>>);

fn object(pairs: &[(&str, Value)]) -> Value {
    let mut dict = Dict::new();
    for (key, value) in pairs {
        dict.insert(key, value.clone());
    }
    Value::Dict(dict)
}

impl GitHubApi for FakeGitHub {
    fn executable(&self) -> Option<std::path::PathBuf> {
        Some("/usr/bin/false".into())
    }

    fn api(&self, method: &str, endpoint: &str, body: Option<&Value>) -> Result<Value> {
        let mut remote = self.0.lock().unwrap();
        remote.calls.push(format!("{method} {endpoint}"));
        let body = body.and_then(Value::as_dict).cloned().unwrap_or_default();
        let prefix = format!("repos/{REPO}");
        if (method, endpoint) == ("GET", "user") {
            return Ok(object(&[("id", Value::Int(7)), ("login", OWNER.into())]));
        }
        if (method, endpoint) == ("POST", "user/repos") {
            remote.created = true;
            remote.description = body.string("description");
            let mut readme = BTreeMap::new();
            let content = b"# readme\n".to_vec();
            let blob = git_blob_id(&content);
            remote.blobs.insert(blob.clone(), content);
            readme.insert("README.md".to_string(), blob);
            remote.head = remote.commit(readme);
        }
        if endpoint == prefix || (method, endpoint) == ("POST", "user/repos") {
            if !remote.created {
                return Err(storage_error(
                    "missing",
                    "The GitHub object is missing or inaccessible.",
                ));
            }
            return Ok(object(&[
                ("id", Value::Int(99)),
                ("node_id", "R_99".into()),
                ("private", Value::Bool(true)),
                ("visibility", "private".into()),
                ("owner", object(&[("id", Value::Int(7))])),
                ("permissions", object(&[("push", Value::Bool(true))])),
                ("full_name", REPO.into()),
                ("html_url", "https://github.com/octo/octo-rr-files".into()),
                (
                    "clone_url",
                    "https://github.com/octo/octo-rr-files.git".into(),
                ),
                ("default_branch", "main".into()),
                ("description", remote.description.clone().into()),
            ]));
        }
        let rest = endpoint
            .strip_prefix(&format!("{prefix}/git/"))
            .ok_or_else(|| Error::value(format!("unexpected endpoint {endpoint}")))?;
        match (method, rest.split_once('/').unwrap_or((rest, ""))) {
            ("GET", ("ref", "heads/main")) => Ok(object(&[(
                "object",
                object(&[("sha", remote.head.clone().into())]),
            )])),
            ("GET", ("commits", sha)) => {
                let tree = remote
                    .commits
                    .get(sha)
                    .cloned()
                    .ok_or_else(|| storage_error("missing", "no commit"))?;
                Ok(object(&[("tree", object(&[("sha", tree.into())]))]))
            }
            ("GET", ("trees", query)) => {
                let sha = query.trim_end_matches("?recursive=1");
                let tree = remote.trees.get(sha).cloned().unwrap_or_default();
                let rows = tree
                    .into_iter()
                    .map(|(path, sha)| {
                        object(&[
                            ("path", path.into()),
                            ("type", "blob".into()),
                            ("sha", sha.into()),
                        ])
                    })
                    .collect();
                Ok(object(&[
                    ("tree", Value::List(rows)),
                    ("truncated", Value::Bool(false)),
                ]))
            }
            ("GET", ("blobs", sha)) => {
                let content = remote
                    .blobs
                    .get(sha)
                    .cloned()
                    .ok_or_else(|| storage_error("missing", "no blob"))?;
                Ok(object(&[
                    ("sha", sha.into()),
                    ("encoding", "base64".into()),
                    ("size", Value::Int(content.len() as i64)),
                    ("content", b64encode(&content).into()),
                ]))
            }
            ("POST", ("blobs", "")) => {
                let content = b64decode_strict(&body.string("content")).unwrap();
                let sha = git_blob_id(&content);
                remote.blobs.insert(sha.clone(), content);
                Ok(object(&[("sha", sha.into())]))
            }
            ("POST", ("trees", "")) => {
                let base = body.string("base_tree");
                let mut tree = remote.trees.get(&base).cloned().unwrap_or_default();
                for item in body
                    .get("tree")
                    .and_then(Value::as_list)
                    .unwrap_or_default()
                {
                    let item = item.as_dict().unwrap();
                    tree.insert(item.string("path"), item.string("sha"));
                }
                let id = remote.id();
                remote.trees.insert(id.clone(), tree);
                Ok(object(&[("sha", id.into())]))
            }
            ("POST", ("commits", "")) => {
                let id = remote.id();
                let tree = body.string("tree");
                remote.commits.insert(id.clone(), tree);
                Ok(object(&[("sha", id.into())]))
            }
            ("PATCH", ("refs", "heads/main")) => {
                assert!(matches!(body.get("force"), Some(Value::Bool(false))));
                remote.head = body.string("sha");
                Ok(object(&[]))
            }
            _ => Err(Error::value(format!("unexpected {method} {endpoint}"))),
        }
    }
}

fn post(storage: &PersonalFileStorage, route: &str, payload: Dict) -> Result<Dict> {
    handle_personal_storage_request(
        storage,
        "POST",
        &format!("/v1/personal-storage/{route}"),
        Some(&payload),
    )
    .unwrap()
}

fn payload(pairs: &[(&str, Value)]) -> Dict {
    object(pairs).as_dict().cloned().unwrap()
}

fn completed_note(manager: &dyn NoteManager) -> String {
    let mut segment = Dict::new();
    segment.insert("segment_id", "s1");
    segment.insert("captured_at", "2026-08-04T05:00:00Z");
    segment.insert("text", "Migrated with its history.");
    let created = manager
        .create(&CreateNote {
            request_id: "c-1".into(),
            created_at: "2026-08-04T05:00:00Z".into(),
            capture_started_at: "2026-08-04T05:00:00Z".into(),
            captured_at: "2026-08-04T05:00:00Z".into(),
            recording_state: "recording".into(),
            checkpoint_reason: "checkpoint".into(),
            segments: Value::List(vec![Value::Dict(segment.clone())]),
            capture_ended_at: None,
            provider: None,
        })
        .unwrap();
    let identity = created
        .get("note")
        .and_then(Value::as_dict)
        .unwrap()
        .get("identity")
        .cloned()
        .unwrap();
    let mut update = Dict::new();
    update.insert("identity", identity);
    update.insert("captured_at", "2026-08-04T05:01:00Z");
    update.insert("recording_state", "completed");
    update.insert("checkpoint_reason", "complete");
    update.insert("capture_ended_at", "2026-08-04T05:01:00Z");
    update.insert("segments", Value::List(vec![Value::Dict(segment)]));
    manager.update("u-1", &update, None).unwrap();
    manager.get("RR-N1").unwrap().string("markdown_base64")
}

#[test]
fn configure_sync_migrate_evict_and_retrieve() {
    let root = TempRoot::new("sync");
    let github = FakeGitHub::default();
    let library = Arc::new(GlobalNoteLibrary::new(
        &root.state_root(),
        DEVICE,
        Box::new(Vec::new),
    ));
    let storage = Arc::new(
        PersonalFileStorage::open(
            &root.state_root(),
            Some(GitHubFiles::new(Box::new(github.clone()))),
            Some(Box::new(|| 1_800_000_000.0)),
        )
        .unwrap(),
    );
    storage.attach_notes(&library).unwrap();
    let markdown = completed_note(library.manager().unwrap().as_ref());

    // Configuring creates our private repository and its identity marker.
    let status = post(
        &storage,
        "configure",
        payload(&[("confirm", Value::Bool(true))]),
    )
    .unwrap();
    assert_eq!(status.string("state"), "pending");
    assert!(status.get("connected").unwrap().truthy());
    let destination = status.get("destination").and_then(Value::as_dict).unwrap();
    assert_eq!(destination.string("full_name"), REPO);

    // A document under files/ is discovered and published once approved.
    let documents = root.state_root().join("files/documents");
    fs::write(documents.join("plan.md"), "# Plan\n").unwrap();
    let synced = post(&storage, "sync", payload(&[("approve", Value::Bool(true))])).unwrap();
    assert_eq!(
        synced.string("state"),
        "synced",
        "{:?}",
        synced.get("message")
    );

    // The global notes moved into personal storage, history bundle included,
    // and the legacy repository is gone.
    assert!(!root.state_root().join("notes").exists());
    assert!(storage.get("notes_migrated", Value::Null).unwrap().truthy());
    let manager = library.manager().unwrap();
    let note = manager.get("RR-N1").unwrap();
    assert_eq!(note.string("markdown_base64"), markdown);
    assert!(
        note.get("reference")
            .and_then(Value::as_dict)
            .unwrap()
            .get("personal_file_id")
            .is_some()
    );
    let files = storage.list_files("").unwrap();
    let ids: Vec<String> = files
        .get("files")
        .and_then(Value::as_list)
        .unwrap()
        .iter()
        .map(|file| file.as_dict().unwrap().string("artifact_id"))
        .collect();
    assert!(
        ids.contains(&"legacy-global-notes-history".to_string()),
        "{ids:?}"
    );
    for file in files.get("files").and_then(Value::as_list).unwrap() {
        let file = file.as_dict().unwrap();
        assert!(file.get("remote_commit").unwrap().truthy(), "{file:?}");
    }
    {
        let remote = github.0.lock().unwrap();
        let tree = &remote.trees[&remote.commits[&remote.head]];
        assert!(tree.contains_key(".relay-runner-storage.json"));
        assert!(tree.contains_key("relay-catalog.json"));
    }

    // Retention evicts verified copies once past the window; a read brings
    // the document back from its immutable remote revision.
    let document = ids
        .iter()
        .find(|id| id.starts_with("document-"))
        .unwrap()
        .clone();
    let reference = storage.reference(&document, None).unwrap();
    let cached = root.state_root().join(reference.string("local_path"));
    assert!(cached.is_file());
    let evicted = post(
        &storage,
        "policy",
        payload(&[
            ("budget_bytes", Value::Int(1)),
            ("retention_days", Value::Int(0)),
        ]),
    )
    .unwrap();
    assert!(
        evicted
            .get("reclaimed_bytes")
            .and_then(Value::py_int)
            .unwrap()
            > 0
    );
    assert!(!cached.exists());
    assert!(!documents.join("plan.md").exists());
    let retrieved = post(
        &storage,
        "retrieve",
        payload(&[("artifact_id", document.as_str().into())]),
    )
    .unwrap();
    assert_eq!(
        b64decode_strict(&retrieved.string("content_base64")).unwrap(),
        b"# Plan\n"
    );
    assert!(cached.is_file());
    // The source document is restored beside the cache.
    assert_eq!(fs::read(documents.join("plan.md")).unwrap(), b"# Plan\n");

    // Disconnecting stops uploads. The evicted note version now needs the
    // remote, so reading it asks to reconnect rather than inventing content.
    let disconnected = post(&storage, "disconnect", Dict::new()).unwrap();
    assert_eq!(disconnected.string("state"), "disconnected");
    let error = manager.get("RR-N1").unwrap_err();
    assert_eq!(
        (error.class, error.state.as_deref()),
        ("StorageError", Some("disconnected"))
    );
}

#[test]
fn an_unrelated_repository_is_not_adopted() {
    let root = TempRoot::new("unrelated");
    let github = FakeGitHub::default();
    {
        let mut remote = github.0.lock().unwrap();
        remote.created = true;
        remote.description = "someone else's".to_string();
        let mut tree = BTreeMap::new();
        let content = b"code".to_vec();
        let blob = git_blob_id(&content);
        remote.blobs.insert(blob.clone(), content);
        tree.insert("main.rs".to_string(), blob);
        remote.head = remote.commit(tree);
    }
    let storage = PersonalFileStorage::open(
        &root.state_root(),
        Some(GitHubFiles::new(Box::new(github))),
        None,
    )
    .unwrap();
    let error = post(
        &storage,
        "configure",
        payload(&[("confirm", Value::Bool(true))]),
    )
    .unwrap_err();
    assert_eq!(error.class, "StorageError");
    assert_eq!(error.state.as_deref(), Some("conflict"));
    assert_eq!(
        error.message,
        "This existing repository is unrelated. Select a Relay storage repo or a new name."
    );
    assert!(!storage.get("connected", Value::Null).unwrap().truthy());
}
