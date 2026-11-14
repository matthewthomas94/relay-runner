//! A test driver for the notes library and personal storage: one JSON
//! request per stdin line, one JSON answer per stdout line.
//! `tests/contract/test_orchestrator_contract_notes_crate.py` runs the RR-485
//! notes and personal-storage cases through it inside the suite's sandbox,
//! with the fake `claude` and `gh` on `PATH`.
//!
//! The first request is `{"op": "open", "state_root": ..., "config": {...},
//! "device_id": ...}`; it wires the library, storage and metadata queue as
//! the daemon does. Then each request is `{"op": "<route>", ...arguments}`
//! and the answer `{"ok": true, "result": ...}` or `{"ok": false, "error":
//! "<Python class>", "message": "<str(exception)>", "state": ...}`.
//! It is an example, so `cargo test` builds it and no release ships it.

use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use relay_intents::json::{self, Dict, Value};
use relay_services::notes::global::GlobalNoteLibrary;
use relay_services::notes::metadata::{NoteMetadataGenerator, NoteMetadataQueue};
use relay_services::notes::{CreateNote, NoteManager, checked_update, retry_metadata};
use relay_services::personal_storage::{PersonalFileStorage, handle_personal_storage_request};
use relay_services::{Error, Result};

struct Daemon {
    library: Arc<GlobalNoteLibrary>,
    storage: Arc<PersonalFileStorage>,
    queue: NoteMetadataQueue,
}

fn text(request: &Dict, key: &str) -> String {
    request.get(key).map(Value::py_str).unwrap_or_default()
}

fn optional(request: &Dict, key: &str) -> Option<String> {
    request.present(key).map(Value::py_str)
}

/// `_find_agent_bin(agent, configured)` for an absolute configured path or
/// `PATH`.
fn find_binary(agent: &str, configured: &str) -> Result<String> {
    if !configured.is_empty() {
        if Path::new(configured).is_file() {
            return Ok(configured.to_string());
        }
        return Err(Error::runtime(format!(
            "{agent} CLI not found: {configured}"
        )));
    }
    std::env::var_os("PATH")
        .and_then(|path| {
            std::env::split_paths(&path)
                .map(|directory| directory.join(agent))
                .find(|candidate| candidate.is_file())
        })
        .map(|path| path.to_string_lossy().into_owned())
        .ok_or_else(|| Error::runtime(format!("{agent} CLI not found on PATH")))
}

impl Daemon {
    fn open(request: &Dict) -> Result<Self> {
        let state_root = PathBuf::from(text(request, "state_root"));
        let config = request
            .get("config")
            .and_then(Value::as_dict)
            .cloned()
            .unwrap_or_default();
        let device_id = text(request, "device_id");
        let library = Arc::new(GlobalNoteLibrary::new(
            &state_root,
            &device_id,
            Box::new(Vec::new),
        ));
        let storage = Arc::new(PersonalFileStorage::open(&state_root, None, None)?);
        storage.attach_notes(&library)?;
        let generator =
            NoteMetadataGenerator::new(Box::new(move || config.clone()), Box::new(find_binary));
        let queue = NoteMetadataQueue::new(Arc::new(generator), Duration::from_secs(2), 128);
        Ok(Self {
            library,
            storage,
            queue,
        })
    }

    fn schedule(&self, manager: &Arc<dyn NoteManager>, result: &Dict) {
        let artifact_id = result
            .get("note")
            .and_then(Value::as_dict)
            .and_then(|note| note.get("identity"))
            .and_then(Value::as_dict)
            .map(|identity| identity.string("artifact_id"))
            .unwrap_or_default();
        self.queue.schedule(manager.clone(), &artifact_id);
    }

    fn call(&self, op: &str, request: &Dict) -> Result<Value> {
        let manager = || self.library.manager();
        let dict = |result: Result<Dict>| result.map(Value::Dict);
        match op {
            "create" => {
                let manager = manager()?;
                let created = manager.create(&CreateNote {
                    request_id: text(request, "request_id"),
                    created_at: text(request, "created_at"),
                    capture_started_at: text(request, "capture_started_at"),
                    captured_at: text(request, "captured_at"),
                    recording_state: text(request, "recording_state"),
                    checkpoint_reason: text(request, "checkpoint_reason"),
                    segments: request.get("segments").cloned().unwrap_or(Value::Null),
                    capture_ended_at: optional(request, "capture_ended_at"),
                    provider: optional(request, "provider"),
                })?;
                self.schedule(&manager, &created);
                Ok(Value::Dict(created))
            }
            "update" => {
                let note_id = text(request, "note_id");
                let update =
                    checked_update(&note_id, request.get("update").unwrap_or(&Value::Null))?;
                let manager = manager()?;
                let updated = manager.update(
                    &text(request, "request_id"),
                    update,
                    optional(request, "provider").as_deref(),
                )?;
                self.schedule(&manager, &updated);
                Ok(Value::Dict(updated))
            }
            "retry_metadata" => {
                let note_id = text(request, "note_id");
                let manager = manager()?;
                retry_metadata(manager.as_ref(), &note_id)?;
                let current = manager.get(&note_id)?;
                self.schedule(&manager, &current);
                dict(manager.get(&note_id))
            }
            "get" => dict(manager()?.get(&text(request, "identity"))),
            "list" => dict(self.library.list(
                request.get("limit").and_then(Value::py_int).unwrap_or(50),
                optional(request, "after").as_deref(),
            )),
            "archive" => dict(manager()?.archive(
                &text(request, "note_id"),
                &text(request, "artifact_id"),
                &text(request, "archived_at"),
                &text(request, "request_id"),
                optional(request, "provider").as_deref(),
            )),
            "delete" | "cancel" => dict(manager()?.delete(
                &text(request, "note_id"),
                &text(request, "artifact_id"),
                &text(request, "request_id"),
                op == "cancel",
            )),
            "wait_idle" => {
                let deadline = Instant::now() + Duration::from_secs(60);
                while !self.queue.is_idle() && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(20));
                }
                Ok(Value::Bool(self.queue.is_idle()))
            }
            "storage" => {
                let payload = request.get("payload").and_then(Value::as_dict).cloned();
                handle_personal_storage_request(
                    &self.storage,
                    &text(request, "method"),
                    &text(request, "path"),
                    payload.as_ref(),
                )
                .unwrap_or_else(|| Err(Error::value("not a personal storage route")))
                .map(Value::Dict)
            }
            other => Err(Error::value(format!("unknown op {other}"))),
        }
    }
}

fn answer(result: Result<Value>) -> Value {
    let mut out = Dict::new();
    match result {
        Ok(value) => {
            out.insert("ok", true);
            out.insert("result", value);
        }
        Err(error) => {
            out.insert("ok", false);
            out.insert("error", error.class);
            out.insert("message", error.message);
            out.insert("state", error.state);
        }
    }
    Value::Dict(out)
}

fn main() {
    let mut daemon: Option<Daemon> = None;
    let stdout = io::stdout();
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let request = json::parse(&line)
            .and_then(|value| value.as_dict().cloned())
            .unwrap_or_default();
        let op = text(&request, "op");
        let result = match (&daemon, op.as_str()) {
            (_, "open") => Daemon::open(&request).map(|opened| {
                daemon = Some(opened);
                Value::Bool(true)
            }),
            (Some(daemon), _) => daemon.call(&op, &request),
            (None, _) => Err(Error::value("open first")),
        };
        let mut handle = stdout.lock();
        let _ = writeln!(handle, "{}", json::dumps(&answer(result)));
        let _ = handle.flush();
    }
    if let Some(daemon) = daemon {
        daemon.queue.shutdown();
    }
}
