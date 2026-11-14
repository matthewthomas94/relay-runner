//! A Rust and a Python daemon take turns on one notes library (RR-499).
//!
//! The Python side is `services/global_notes.py` and `personal_notes.py`,
//! run on the same state root. Notes either side writes read back through
//! the other exactly as the writer reads them: the full `get` and `list`
//! responses, Markdown, references and sync state.

mod common;

use std::path::Path;
use std::sync::Arc;

use relay_intents::json::{self, Dict, Value};
use relay_services::notes::global::GlobalNoteLibrary;
use relay_services::notes::personal::PersonalNoteManager;
use relay_services::notes::{CreateNote, NoteManager};
use relay_services::personal_storage::PersonalFileStorage;

use common::{TempRoot, python, run_python};

const DEVICE: &str = "daemon-0123456789abcdef01234567";

const PYTHON_LIBRARY: &str = r#"
import json
from pathlib import Path
from global_notes import GlobalNoteLibrary
from personal_file_storage import PersonalFileStorage
from personal_notes import PersonalNoteManager
root, mode, action = sys.argv[1], sys.argv[2], sys.argv[3]
if mode == "personal":
    manager = PersonalNoteManager(PersonalFileStorage(root), "daemon-0123456789abcdef01234567")
else:
    manager = GlobalNoteLibrary(Path(root), "daemon-0123456789abcdef01234567", lambda: []).manager
segment = lambda sid, at, text: {"segment_id": sid, "captured_at": at, "text": text, "start_ms": 0, "end_ms": 10}
out = {}
if action == "write":
    created = manager.create(request_id="py-create", created_at="2026-08-04T05:00:00Z",
        capture_started_at="2026-08-04T05:00:00Z", captured_at="2026-08-04T05:00:00Z",
        recording_state="recording", checkpoint_reason="checkpoint",
        segments=[segment("a", "2026-08-04T05:00:00Z", "Python wrote this — café.")], provider="codex")
    identity = created["note"]["identity"]
    manager.update(request_id="py-update", update={"identity": identity, "captured_at": "2026-08-04T05:02:00Z",
        "recording_state": "completed", "checkpoint_reason": "complete", "capture_ended_at": "2026-08-04T05:02:00Z",
        "segments": [segment("a", "2026-08-04T05:00:00Z", "Python wrote this — café."),
                     segment("b", "2026-08-04T05:01:00Z", "Second line.")]}, provider="codex")
for note_id in sys.argv[4:]:
    out[note_id] = manager.get(note_id)
out["list"] = manager.list(limit=50)
print(json.dumps(out, sort_keys=True))
"#;

fn python_view(python: &Path, root: &TempRoot, mode: &str, action: &str, ids: &[&str]) -> Value {
    let state_root = root.state_root();
    let state = state_root.to_string_lossy();
    let mut arguments = vec![state.as_ref(), mode, action];
    arguments.extend_from_slice(ids);
    let output = run_python(python, &state_root, PYTHON_LIBRARY, &arguments);
    json::parse(output.trim()).expect("python JSON")
}

fn rust_view(manager: &dyn NoteManager, ids: &[&str]) -> Value {
    let mut out = Dict::new();
    for id in ids {
        out.insert(id, manager.get(id).expect("rust get"));
    }
    out.insert("list", manager.list(50, None).expect("rust list"));
    Value::Dict(out)
}

fn segment(id: &str, at: &str, text: &str) -> Value {
    let mut segment = Dict::new();
    segment.insert("segment_id", id);
    segment.insert("captured_at", at);
    segment.insert("text", text);
    segment.insert("start_ms", 0);
    segment.insert("end_ms", 10);
    Value::Dict(segment)
}

fn rust_write(manager: &dyn NoteManager) -> String {
    let created = manager
        .create(&CreateNote {
            request_id: "rs-create".into(),
            created_at: "2026-08-04T06:00:00Z".into(),
            capture_started_at: "2026-08-04T06:00:00Z".into(),
            captured_at: "2026-08-04T06:00:00Z".into(),
            recording_state: "recording".into(),
            checkpoint_reason: "checkpoint".into(),
            segments: Value::List(vec![segment(
                "x",
                "2026-08-04T06:00:00Z",
                "Rust wrote ünïcode.",
            )]),
            capture_ended_at: None,
            provider: Some("claude".into()),
        })
        .expect("rust create");
    let identity = at(&created, &["note", "identity"]);
    let mut update = Dict::new();
    update.insert("identity", identity.clone());
    update.insert("captured_at", "2026-08-04T06:03:00Z");
    update.insert("recording_state", "completed");
    update.insert("checkpoint_reason", "complete");
    update.insert("capture_ended_at", "2026-08-04T06:03:00Z");
    update.insert(
        "segments",
        Value::List(vec![
            segment("x", "2026-08-04T06:00:00Z", "Rust wrote ünïcode."),
            segment("y", "2026-08-04T06:01:00Z", "And more."),
        ]),
    );
    manager
        .update("rs-update", &update, Some("claude"))
        .expect("rust update");
    identity.as_dict().unwrap().string("note_id")
}

/// `value[a][b]...`.
fn at(value: &Dict, path: &[&str]) -> Value {
    let mut current = Value::Dict(value.clone());
    for key in path {
        current = current
            .as_dict()
            .and_then(|dict| dict.get(key))
            .cloned()
            .expect(key);
    }
    current
}

fn assert_same(rust: &Value, python: &Value, what: &str) {
    assert_eq!(
        json::dumps_sorted(rust),
        json::dumps_sorted(python),
        "{what}: Rust and Python read differently"
    );
}

#[test]
fn artifact_notes_round_trip_between_python_and_rust() {
    let Some(python) = python() else { return };
    let root = TempRoot::new("artifact-notes");
    // Python writes first; Rust reads what Python reads.
    let theirs = python_view(&python, &root, "artifact", "write", &["RR-N1"]);
    let library = GlobalNoteLibrary::new(&root.state_root(), DEVICE, Box::new(Vec::new));
    let manager = library.manager().unwrap();
    assert_same(
        &rust_view(manager.as_ref(), &["RR-N1"]),
        &theirs,
        "Python-written note",
    );

    // Rust writes a second note; Python reads both as Rust does.
    let note_id = rust_write(manager.as_ref());
    assert_eq!(note_id, "RR-N2");
    let ours = rust_view(manager.as_ref(), &["RR-N1", "RR-N2"]);
    let theirs = python_view(&python, &root, "artifact", "read", &["RR-N1", "RR-N2"]);
    assert_same(&ours, &theirs, "Rust-written note");

    // Rust's request receipts are Python's: repeating Python's create in
    // Rust is idempotent.
    let repeated = manager
        .create(&CreateNote {
            request_id: "py-create".into(),
            created_at: "2026-08-04T05:00:00Z".into(),
            capture_started_at: "2026-08-04T05:00:00Z".into(),
            captured_at: "2026-08-04T05:00:00Z".into(),
            recording_state: "recording".into(),
            checkpoint_reason: "checkpoint".into(),
            segments: Value::List(vec![segment(
                "a",
                "2026-08-04T05:00:00Z",
                "Python wrote this — café.",
            )]),
            capture_ended_at: None,
            provider: Some("codex".into()),
        })
        .unwrap();
    assert!(at(&repeated, &["idempotent"]).truthy());
    assert!(at(&repeated, &["note", "identity", "note_id"]).is_str("RR-N1"));
}

#[test]
fn personal_notes_round_trip_between_python_and_rust() {
    let Some(python) = python() else { return };
    let root = TempRoot::new("personal-notes");
    let theirs = python_view(&python, &root, "personal", "write", &["RR-N1"]);
    let storage = Arc::new(PersonalFileStorage::open(&root.state_root(), None, None).unwrap());
    let manager = PersonalNoteManager::new(storage, DEVICE).unwrap();
    assert_same(
        &rust_view(&manager, &["RR-N1"]),
        &theirs,
        "Python-written personal note",
    );

    let note_id = rust_write(&manager);
    assert_eq!(note_id, "RR-N2");
    let ours = rust_view(&manager, &["RR-N1", "RR-N2", "N2"]);
    let theirs = python_view(
        &python,
        &root,
        "personal",
        "read",
        &["RR-N1", "RR-N2", "N2"],
    );
    assert_same(&ours, &theirs, "Rust-written personal note");
}
