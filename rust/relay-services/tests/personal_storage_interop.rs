//! Personal storage on one state root (RR-499): files cached, discovered,
//! pinned or given a policy read back through a store reopened on the same
//! root: references, the file list, content and status. The database's own
//! size moves as each store opens and checkpoints its WAL, so status is
//! compared without the byte counts that include it.

mod common;

use std::fs;

use relay_intents::json::{self, Dict, Value};
use relay_services::personal_storage::{PersonalFileStorage, handle_personal_storage_request};

use common::TempRoot;

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

fn view(storage: &PersonalFileStorage) -> Dict {
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

/// The file list without `accessed`, which each `read()` moves on after the
/// list was taken.
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

fn assert_same(written: &Dict, reopened: &Dict, what: &str) {
    assert_eq!(
        json::dumps_sorted(&listed(written)),
        json::dumps_sorted(&listed(reopened)),
        "{what}: files differ"
    );
    for key in ["contents", "configure"] {
        assert_eq!(
            json::dumps_sorted(written.get(key).unwrap()),
            json::dumps_sorted(reopened.get(key).unwrap()),
            "{what}: {key} differs"
        );
    }
    assert_eq!(
        json::dumps_sorted(&stable(written.get("status").unwrap())),
        json::dumps_sorted(&stable(reopened.get("status").unwrap())),
        "{what}: status differs"
    );
}

#[test]
fn files_and_catalog_read_back_through_a_reopened_store() {
    let root = TempRoot::new("personal-files");
    // A user document and a General task file, discovered on open.
    let documents = root.state_root().join("files/documents/plans");
    fs::create_dir_all(&documents).unwrap();
    fs::write(documents.join("roadmap.md"), "# Roadmap\n").unwrap();
    let general = root.state_root().join("general-tasks/GEN-1");
    fs::create_dir_all(&general).unwrap();
    fs::write(general.join("draft.txt"), "draft\n").unwrap();

    // An approved inactive version, then an active one, pinned, with a
    // policy; a second store on the same root reads the same catalog.
    let task = json::parse(r#"{"task": "GEN-1"}"#).unwrap();
    let storage = PersonalFileStorage::open(&root.state_root(), None, None).unwrap();
    storage
        .put(
            "task-1",
            "tasks/task-1/output.md",
            b"# Output\n",
            "tasks",
            Some(&task),
            false,
            Some(true),
            true,
        )
        .unwrap();
    storage
        .put(
            "task-1",
            "tasks/task-1/output.md",
            b"# Output v2\n",
            "tasks",
            Some(&task),
            false,
            None,
            true,
        )
        .unwrap();
    storage.pin("task-1", true).unwrap();
    storage
        .policy(&Value::Int(64 * 1024 * 1024), &Value::Int(3))
        .unwrap();
    let ours = view(&storage);
    drop(storage);
    let reopened = PersonalFileStorage::open(&root.state_root(), None, None).unwrap();
    assert_same(&ours, &view(&reopened), "first catalog");

    // A new version and a note file, unpinned, with a new policy.
    reopened
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
    reopened.pin("task-1", false).unwrap();
    reopened
        .policy(&Value::Int(32 * 1024 * 1024), &Value::Int(9))
        .unwrap();
    fs::write(documents.join("roadmap.md"), "# Roadmap v2\n").unwrap();
    let ours = view(&reopened);
    drop(reopened);
    let again = PersonalFileStorage::open(&root.state_root(), None, None).unwrap();
    let theirs = view(&again);
    assert_same(&ours, &theirs, "second catalog");
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
