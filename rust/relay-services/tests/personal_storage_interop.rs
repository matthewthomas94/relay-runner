//! A Rust and a Python daemon take turns on one personal-storage catalog
//! and cache (RR-499).
//!
//! The Python side is `services/personal_file_storage.py` on the same state
//! root. Files either side caches, discovers, pins or sets policy for read
//! back through the other: references, the file list, content and status.
//! The database's own size moves as each process opens and checkpoints its
//! WAL, so status is compared without the byte counts that include it.

mod common;

use std::fs;
use std::path::Path;

use relay_intents::json::{self, Dict, Value};
use relay_services::personal_storage::{PersonalFileStorage, handle_personal_storage_request};

use common::{TempRoot, python, run_python};

const PYTHON_STORAGE: &str = r##"
import base64, json
from personal_file_storage import PersonalFileStorage, StorageError
root, action = sys.argv[1], sys.argv[2]
storage = PersonalFileStorage(root)
if action == "write":
    storage.put("task-1", "tasks/task-1/output.md", b"# Output\n", category="tasks",
                metadata={"task": "GEN-1"}, active=False, approved=True)
    storage.put("task-1", "tasks/task-1/output.md", b"# Output v2\n", category="tasks",
                metadata={"task": "GEN-1"})
    storage.pin("task-1", True)
    storage.policy(budget_bytes=64 * 1024 * 1024, retention_days=3)
out = {"files": storage.list_files(""), "status": storage.status()}
out["contents"] = {row["artifact_id"]: base64.b64encode(storage.read(row["artifact_id"])).decode()
                   for row in out["files"]["files"]}
try:
    storage.configure(confirm=False)
except StorageError as error:
    out["configure"] = [error.state, str(error)]
print(json.dumps(out, sort_keys=True))
"##;

/// The byte counts that do not include the database file.
const STABLE_USAGE: [&str; 5] = [
    "user_file_bytes",
    "evictable_bytes",
    "protected_bytes",
    "unsynced_bytes",
    "unmanaged_bytes",
];

fn stable(status: &Value) -> Value {
    let mut status = status.as_dict().cloned().unwrap();
    let usage = status
        .get("usage")
        .and_then(Value::as_dict)
        .cloned()
        .unwrap();
    let mut kept = Dict::new();
    for key in STABLE_USAGE {
        kept.insert(key, usage.get(key).cloned().unwrap());
    }
    status.insert("usage", kept);
    status.remove("over_budget");
    status.remove("overage_reasons");
    Value::Dict(status)
}

fn python_view(python: &Path, root: &TempRoot, action: &str) -> Dict {
    let state_root = root.state_root();
    let output = run_python(
        python,
        &state_root,
        PYTHON_STORAGE,
        &[&state_root.to_string_lossy(), action],
    );
    json::parse(output.trim())
        .and_then(|value| value.as_dict().cloned())
        .expect("python JSON")
}

fn rust_view(storage: &PersonalFileStorage) -> Dict {
    let files = storage.list_files("").unwrap();
    let mut contents = Dict::new();
    for file in files.get("files").and_then(Value::as_list).unwrap() {
        let id = file.as_dict().unwrap().string("artifact_id");
        let content = storage.read(&id, None).unwrap();
        let encoded = handle_personal_storage_request(
            storage,
            "POST",
            "/v1/personal-storage/retrieve",
            {
                let mut payload = Dict::new();
                payload.insert("artifact_id", id.as_str());
                Some(payload)
            }
            .as_ref(),
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            encoded.string("content_base64").len(),
            content.len().div_ceil(3) * 4
        );
        contents.insert(&id, encoded.string("content_base64"));
    }
    let mut view = Dict::new();
    view.insert("files", files);
    view.insert("status", storage.status().unwrap());
    view.insert("contents", contents);
    let error = storage
        .configure(&Value::Bool(false), None, true)
        .unwrap_err();
    view.insert(
        "configure",
        Value::List(vec![
            Value::from(error.state.clone()),
            Value::from(error.message.as_str()),
        ]),
    );
    view
}

/// The file list without `accessed`, which each side's `read()` moves on
/// after the other listed.
fn listed(view: &Dict) -> Value {
    let files = view
        .get("files")
        .and_then(Value::as_dict)
        .and_then(|files| files.get("files"))
        .and_then(Value::as_list)
        .unwrap();
    Value::List(
        files
            .iter()
            .map(|file| {
                let mut file = file.as_dict().cloned().unwrap();
                assert!(matches!(file.remove("accessed"), Some(Value::Float(_))));
                Value::Dict(file)
            })
            .collect(),
    )
}

fn assert_same(rust: &Dict, python: &Dict, what: &str) {
    assert_eq!(
        json::dumps_sorted(&listed(rust)),
        json::dumps_sorted(&listed(python)),
        "{what}: files differ"
    );
    for key in ["contents", "configure"] {
        assert_eq!(
            json::dumps_sorted(rust.get(key).unwrap()),
            json::dumps_sorted(python.get(key).unwrap()),
            "{what}: {key} differs"
        );
    }
    assert_eq!(
        json::dumps_sorted(&stable(rust.get("status").unwrap())),
        json::dumps_sorted(&stable(python.get("status").unwrap())),
        "{what}: status differs"
    );
}

#[test]
fn files_and_catalog_round_trip_between_python_and_rust() {
    let Some(python) = python() else { return };
    let root = TempRoot::new("personal-files");
    // A user document and a General task file, discovered by both sides.
    let documents = root.state_root().join("files/documents/plans");
    fs::create_dir_all(&documents).unwrap();
    fs::write(documents.join("roadmap.md"), "# Roadmap\n").unwrap();
    let general = root.state_root().join("general-tasks/GEN-1");
    fs::create_dir_all(&general).unwrap();
    fs::write(general.join("draft.txt"), "draft\n").unwrap();

    let theirs = python_view(&python, &root, "write");
    let storage = PersonalFileStorage::open(&root.state_root(), None, None).unwrap();
    assert_same(&rust_view(&storage), &theirs, "Python-written catalog");

    // Rust caches a new version and a note file, pins and sets policy.
    storage
        .put(
            "task-2",
            "tasks/task-2/report.txt",
            "Rust wrote this.\n".as_bytes(),
            "tasks",
            Some(&json::parse(r#"{"task": "GEN-2"}"#).unwrap()),
            true,
            None,
            true,
        )
        .unwrap();
    storage.pin("task-1", false).unwrap();
    storage
        .policy(&Value::Int(32 * 1024 * 1024), &Value::Int(9))
        .unwrap();
    fs::write(documents.join("roadmap.md"), "# Roadmap v2\n").unwrap();
    let ours = rust_view(&storage);
    drop(storage);
    let theirs = python_view(&python, &root, "read");
    assert_same(&ours, &theirs, "Rust-written catalog");
    let status = theirs.get("status").and_then(Value::as_dict).unwrap();
    assert_eq!(
        status.get("budget_bytes").and_then(Value::py_int),
        Some(32 * 1024 * 1024)
    );
    assert_eq!(
        status.get("retention_days").and_then(Value::py_int),
        Some(9)
    );
}
