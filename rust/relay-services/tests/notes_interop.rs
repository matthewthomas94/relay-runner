//! Notes on one state root (RR-499): a note written and completed through
//! the artifact library or personal storage reads back through a second
//! manager opened on the same root exactly as the writer reads it (the full
//! `get` and `list` responses, Markdown, references and sync state), and a
//! repeated create request is answered from its receipt.

mod common;

use std::sync::Arc;

use relay_intents::json::{self, Dict, Value};
use relay_services::notes::global::GlobalNoteLibrary;
use relay_services::notes::personal::PersonalNoteManager;
use relay_services::notes::{CreateNote, NoteManager};
use relay_services::personal_storage::PersonalFileStorage;

use common::TempRoot;

const DEVICE: &str = "daemon-0123456789abcdef01234567";

fn view(manager: &dyn NoteManager, ids: &[&str]) -> Value {
    let mut out = Dict::new();
    for id in ids {
        out.insert(id, manager.get(id).expect("get"));
    }
    out.insert("list", manager.list(50, None).expect("list"));
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

fn first_create() -> CreateNote {
    CreateNote {
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
    }
}

fn write_note(manager: &dyn NoteManager) -> String {
    let created = manager.create(&first_create()).expect("create");
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
        .expect("update");
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

fn assert_same(written: &Value, reopened: &Value, what: &str) {
    assert_eq!(
        json::dumps_sorted(written),
        json::dumps_sorted(reopened),
        "{what}: the reopened manager reads differently"
    );
}

#[test]
fn artifact_notes_read_back_through_a_reopened_library() {
    let root = TempRoot::new("artifact-notes");
    let library = GlobalNoteLibrary::new(&root.state_root(), DEVICE, Box::new(Vec::new));
    let manager = library.manager().unwrap();
    let note_id = write_note(manager.as_ref());
    assert_eq!(note_id, "RR-N1");
    let ours = view(manager.as_ref(), &["RR-N1"]);

    let reopened = GlobalNoteLibrary::new(&root.state_root(), DEVICE, Box::new(Vec::new));
    let reopened = reopened.manager().unwrap();
    assert_same(&ours, &view(reopened.as_ref(), &["RR-N1"]), "artifact note");

    // Repeating the create request is idempotent.
    let repeated = reopened.create(&first_create()).unwrap();
    assert!(at(&repeated, &["idempotent"]).truthy());
    assert!(at(&repeated, &["note", "identity", "note_id"]).is_str("RR-N1"));
}

#[test]
fn personal_notes_read_back_through_a_reopened_manager() {
    let root = TempRoot::new("personal-notes");
    let storage = Arc::new(PersonalFileStorage::open(&root.state_root(), None, None).unwrap());
    let manager = PersonalNoteManager::new(storage, DEVICE).unwrap();
    let note_id = write_note(&manager);
    assert_eq!(note_id, "RR-N1");
    let ours = view(&manager, &["RR-N1", "N1"]);

    let storage = Arc::new(PersonalFileStorage::open(&root.state_root(), None, None).unwrap());
    let reopened = PersonalNoteManager::new(storage, DEVICE).unwrap();
    assert_same(&ours, &view(&reopened, &["RR-N1", "N1"]), "personal note");
}
