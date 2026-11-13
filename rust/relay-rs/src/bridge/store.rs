//! The bridge's own files: state datagrams to the overlay, the command state
//! ledger and its mirrors, the mailbox, the private command log, the pid and
//! focused-target files (`voice_bridge.py` "Files and sockets").

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixDatagram;
use std::path::Path;
use std::sync::Mutex;

use relay_intents::inbox::IntentInbox;

use super::settings::{dirname, normpath, settings};
use super::targets;
use crate::json::{self, Dict, Value};

/// `_VOICE_STATE_LOCK`: serializes every read-modify-write of the command
/// state file.
pub static VOICE_STATE_LOCK: Mutex<()> = Mutex::new(());
static COMMAND_EVENT_LOG_LOCK: Mutex<()> = Mutex::new(());

const VOICE_COMMAND_EVENT_LIMIT: usize = 200;
const COMMAND_ACTION_RECOVERY_STATES: [&str; 3] = ["claimed", "delivery_failed", "superseded"];
const COMMAND_ACTION_TERMINAL_STATES: [&str; 2] = ["delivery_failed", "superseded"];

/// Locks `VOICE_STATE_LOCK`, surviving a panicked holder.
pub fn voice_state_lock() -> std::sync::MutexGuard<'static, ()> {
    VOICE_STATE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// `_notify_state(state, **kwargs)`: one datagram to the overlay.
pub fn notify_state(state: &str, fields: Dict) {
    let mut message = Dict::new();
    message.insert("source", "bridge");
    message.insert("state", state);
    message.update(&fields);
    send_state_datagram(json::dumps(&Value::Dict(message)).as_bytes());
}

/// Sends one datagram to `VOICE_STATE_SOCK`, ignoring every failure.
pub fn send_state_datagram(data: &[u8]) {
    if let Ok(socket) = UnixDatagram::unbound() {
        let _ = socket.send_to(data, &settings().voice_state_sock);
    }
}

/// `_notify_state(state, text=text)`.
pub fn notify_text(state: &str, text: &str) {
    let mut fields = Dict::new();
    fields.insert("text", text);
    notify_state(state, fields);
}

/// `_read_json_file`: the object in a JSON file, else an empty one.
pub fn read_json_file(path: &str) -> Dict {
    crate::support::read_json_file(path)
}

/// `os.makedirs(path, mode=0o700, exist_ok=True)`.
pub fn make_private_dirs(path: &str) -> io::Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
}

/// `_ensure_session_spool_dir`: recreates a targeted spool the app removed
/// while the bridge still runs.
pub fn ensure_session_spool_dir() {
    let spool = &settings().spool_dir;
    if spool.is_empty() || Path::new(spool).is_dir() {
        return;
    }
    if let Err(error) = make_private_dirs(spool) {
        eprintln!("[voice_bridge] Could not recreate session spool {spool}: {error}");
    }
}

/// `_mirror_command_state`: copies the state file to the legacy path and to
/// every live session's spool.
pub fn mirror_command_state(path: &str) {
    let settings = settings();
    let mut destinations = Vec::new();
    if settings.mirrored_command_state_file.as_deref() == Some(path) {
        destinations.push(settings.legacy_command_state_file.clone());
    }
    if targets::ledger_state_file().as_deref() == Some(path) {
        destinations.extend(
            targets::live_voice_targets()
                .into_iter()
                .map(|target| target.state_path.clone())
                .filter(|state_path| !state_path.is_empty() && state_path != path),
        );
    }
    for destination in destinations {
        let temporary = format!("{destination}.tmp");
        let copied = make_private_dirs(&dirname(&destination))
            .and_then(|()| fs::copy(path, &temporary).map(|_| ()))
            .and_then(|()| fs::rename(&temporary, &destination));
        if copied.is_err() {
            let _ = fs::remove_file(&temporary);
        }
    }
}

/// `_atomic_write_json`: key-sorted JSON through `<path>.tmp`, then mirrored.
pub fn atomic_write_json(path: &str, payload: &Dict) -> io::Result<()> {
    ensure_session_spool_dir();
    let temporary = format!("{path}.tmp");
    fs::write(&temporary, json::dumps_sorted(&Value::Dict(payload.clone())))?;
    fs::rename(&temporary, path)?;
    mirror_command_state(path);
    Ok(())
}

const SESSION_COMMAND_FIELDS: [&str; 4] = [
    "relay_command_seq",
    "relay_command_id",
    "intent_id",
    "work_disposition",
];

/// `_relay_command_key`: an integer sequence and a non-empty id.
pub fn relay_command_key(command: &Dict) -> Option<(i64, String)> {
    crate::support::relay_command_key(command)
}

/// `_relay_command_key` for a value that may not be an object.
pub fn relay_command_key_of(command: Option<&Value>) -> Option<(i64, String)> {
    command.and_then(Value::as_dict).and_then(relay_command_key)
}

/// `_write_command_state`: the shared command ledger, keeping each live
/// session's newest command under `session_commands` (RR-401).
pub fn write_command_state(path: &str, metadata: &Dict) -> io::Result<()> {
    let mut payload = metadata.clone();
    let previous = read_json_file(path);
    let mut sessions = previous
        .get("session_commands")
        .and_then(Value::as_dict)
        .cloned()
        .unwrap_or_default();
    let (session_key, live_keys) = {
        let targets = targets::lock();
        let session_key = match metadata.truthy("voice_target_session_key") {
            Some(value) => value.py_str(),
            None => targets.focused_key.clone().unwrap_or_default(),
        };
        (session_key, targets.keys())
    };
    if !live_keys.is_empty() {
        let mut kept = Dict::new();
        for (key, value) in sessions.iter() {
            if live_keys.iter().any(|live| live == key) {
                kept.insert(key, value.clone());
            }
        }
        sessions = kept;
    }
    if !session_key.is_empty() && relay_command_key(metadata).is_some() {
        let mut entry = Dict::new();
        for field in SESSION_COMMAND_FIELDS {
            if let Some(value) = metadata.get(field) {
                entry.insert(field, value.clone());
            }
        }
        sessions.insert(&session_key, entry);
    }
    if !sessions.is_empty() {
        payload.insert("session_commands", sessions);
    }
    atomic_write_json(path, &payload)
}

/// `sync_deliverable_state`: the inbox's view into the state file, mirrored.
pub fn sync_deliverable_state(state_path: &str, inbox: &IntentInbox) -> io::Result<()> {
    relay_intents::inbox::sync_deliverable_state(state_path, inbox).map_err(|error| match error {
        relay_intents::Error::Io(error) => error,
        other => io::Error::other(other.to_string()),
    })?;
    mirror_command_state(state_path);
    Ok(())
}

/// `_write_cmd_file`: the agent prompt into the mailbox, atomically.
pub fn write_cmd_file(text: &str, path: &str) -> io::Result<()> {
    ensure_session_spool_dir();
    let temporary = format!("{path}.tmp");
    fs::write(&temporary, text)?;
    fs::rename(&temporary, path)
}

/// `Path(path).expanduser().resolve()` (non-strict).
pub fn resolve_path(path: &str) -> String {
    let expanded = if path == "~" || path.starts_with("~/") {
        format!("{}{}", crate::support::env_or("HOME", ""), &path[1..])
    } else {
        path.to_string()
    };
    if let Ok(resolved) = fs::canonicalize(&expanded) {
        return resolved.to_string_lossy().into_owned();
    }
    let absolute = if expanded.starts_with('/') {
        expanded
    } else {
        let cwd = std::env::current_dir()
            .map(|cwd| cwd.to_string_lossy().into_owned())
            .unwrap_or_default();
        format!("{cwd}/{expanded}")
    };
    normpath(&absolute)
}

/// The process working directory, as `os.getcwd()` reports it.
pub fn current_dir() -> String {
    std::env::current_dir()
        .map(|cwd| cwd.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "/".to_string())
}

/// `_command_action_journal_snapshot`: the newest recovery-relevant command
/// states from the private journal.
pub fn command_action_journal_snapshot(
    event_log_path: &str,
    repo_path: Option<&str>,
    limit: usize,
) -> Vec<Dict> {
    if event_log_path.is_empty() {
        return Vec::new();
    }
    let Ok(text) = fs::read_to_string(event_log_path) else {
        return Vec::new();
    };
    let mut by_id: Vec<(String, Dict)> = Vec::new();
    let mut order: Vec<String> = Vec::new();
    for line in text.lines().filter(|line| !json::py_strip(line).is_empty()) {
        let Some(Value::Dict(event)) = json::parse(line) else {
            continue;
        };
        let command_id = event.text("relay_command_id");
        let intent_id = event.text("intent_id");
        let event_id = if intent_id.is_empty() {
            command_id.clone()
        } else {
            intent_id.clone()
        };
        let Some(command_seq) = event.get("relay_command_seq").and_then(Value::py_int) else {
            continue;
        };
        let state = event.text("state").to_lowercase();
        if command_id.is_empty() || state.is_empty() {
            continue;
        }
        let position = by_id.iter().position(|(id, _)| *id == event_id);
        let mut current = match position {
            Some(index) => by_id[index].1.clone(),
            None => {
                let mut fresh = Dict::new();
                fresh.insert("relay_command_id", command_id.as_str());
                fresh.insert("relay_command_seq", command_seq);
                fresh
            }
        };
        if !intent_id.is_empty() {
            current.insert("intent_id", intent_id.as_str());
        }
        for name in [
            "source_text",
            "provider",
            "repo_path",
            "action",
            "outcome",
            "received_at",
            "within_turn_order",
            "target",
            "disposition",
            "cancellation_scope",
            "lifecycle_state",
        ] {
            match event.get(name) {
                None | Some(Value::Null) => {}
                Some(Value::Str(text)) if text.is_empty() => {}
                Some(value) => current.insert(name, value.clone()),
            }
        }
        current.insert("relay_command_seq", command_seq);
        let current_state = current.string("state");
        if COMMAND_ACTION_TERMINAL_STATES.contains(&state.as_str())
            || !COMMAND_ACTION_TERMINAL_STATES.contains(&current_state.as_str())
        {
            current.insert("state", state.as_str());
        }
        order.retain(|id| *id != event_id);
        order.push(event_id.clone());
        match position {
            Some(index) => by_id[index].1 = current,
            None => by_id.push((event_id, current)),
        }
    }
    let resolved_repo = repo_path.map(resolve_path);
    let mut snapshot = Vec::new();
    for event_id in order {
        let Some((_, event)) = by_id.iter().find(|(id, _)| *id == event_id) else {
            continue;
        };
        let mut event = event.clone();
        if !COMMAND_ACTION_RECOVERY_STATES.contains(&event.string("state").as_str()) {
            continue;
        }
        let event_repo = event.truthy("repo_path").map(Value::py_str);
        match (event_repo, &resolved_repo) {
            (Some(event_repo), Some(resolved)) => {
                if resolve_path(&event_repo) != *resolved {
                    continue;
                }
            }
            (None, Some(resolved)) => event.insert("repo_path", resolved.as_str()),
            _ => {}
        }
        snapshot.push(event);
    }
    let keep = limit.max(1);
    if snapshot.len() > keep {
        snapshot.drain(..snapshot.len() - keep);
    }
    snapshot
}

/// `_command_event_limit`.
fn command_event_limit() -> usize {
    crate::support::env_optional("VOICE_COMMAND_EVENT_LIMIT")
        .and_then(|value| json::py_int_from_str(&value))
        .map_or(VOICE_COMMAND_EVENT_LIMIT, |limit| limit.max(1) as usize)
}

/// `_record_private_command_capture`: one bounded private event, outside the
/// visible board files.
pub fn record_private_command_capture(metadata: &Dict) {
    let path = &settings().command_event_log;
    if path.is_empty() {
        return;
    }
    let limit = command_event_limit();
    let mut event = Dict::new();
    event.insert(
        "relay_command_seq",
        metadata.get("relay_command_seq").cloned().unwrap_or(Value::Null),
    );
    event.insert(
        "relay_command_id",
        metadata.get("relay_command_id").cloned().unwrap_or(Value::Null),
    );
    event.insert(
        "received_at",
        metadata.get("received_at").cloned().unwrap_or(Value::Null),
    );
    event.insert(
        "source_text",
        metadata.get("source_text").cloned().unwrap_or(Value::Null),
    );
    event.insert(
        "action",
        metadata
            .get("action")
            .cloned()
            .unwrap_or_else(|| Value::from("received")),
    );
    event.insert(
        "state",
        metadata
            .get("state")
            .cloned()
            .unwrap_or_else(|| Value::from("received")),
    );
    for name in [
        "outcome",
        "repo_path",
        "ticket_id",
        "intent_id",
        "within_turn_order",
        "target",
        "disposition",
        "cancellation_scope",
        "lifecycle_state",
    ] {
        if let Some(value) = metadata.truthy(name) {
            event.insert(name, value.clone());
        }
    }
    if let Some(provider) = metadata.truthy("provider") {
        event.insert("provider", provider.clone());
    }
    let _guard = COMMAND_EVENT_LOG_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Err(error) = append_bounded_line(path, &json::dumps_sorted(&Value::Dict(event)), limit) {
        eprintln!("[voice_bridge] Could not record private command event: {error}");
    }
}

fn append_bounded_line(path: &str, line: &str, limit: usize) -> io::Result<()> {
    let mut existing: Vec<String> = match fs::read_to_string(path) {
        Ok(text) => text
            .lines()
            .filter(|line| !json::py_strip(line).is_empty())
            .map(str::to_string)
            .collect(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
        Err(error) => return Err(error),
    };
    let keep = limit.saturating_sub(1);
    if existing.len() > keep {
        existing.drain(..existing.len() - keep);
    }
    let parent = dirname(path);
    if !parent.is_empty() {
        fs::create_dir_all(&parent)?;
        fs::set_permissions(&parent, fs::Permissions::from_mode(0o700))?;
    }
    let temporary = format!("{path}.tmp");
    {
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)?;
        for previous in &existing {
            file.write_all(previous.as_bytes())?;
            file.write_all(b"\n")?;
        }
        file.write_all(line.as_bytes())?;
        file.write_all(b"\n")?;
    }
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    fs::rename(&temporary, path)
}

/// `_record_command_action_state`.
pub fn record_command_action_state(metadata: &Dict, state: &str) {
    let mut event = metadata.clone();
    event.insert("state", state);
    record_private_command_capture(&event);
}

/// Writes `value` and a newline to `path` through a pid-named temporary file.
fn write_through_temporary(path: &str, value: &str) {
    let temporary = format!("{path}.{}.tmp", std::process::id());
    if fs::write(&temporary, format!("{value}\n"))
        .and_then(|()| fs::rename(&temporary, path))
        .is_err()
    {
        let _ = fs::remove_file(&temporary);
    }
}

/// `_write_bridge_pid_file`.
pub fn write_bridge_pid_file() {
    write_through_temporary(
        &settings().bridge_pid_file,
        &std::process::id().to_string(),
    );
}

/// `_remove_bridge_pid_file`: only while it still names this process.
pub fn remove_bridge_pid_file() {
    let path = &settings().bridge_pid_file;
    if let Ok(text) = fs::read_to_string(path)
        && json::py_strip(&text) == std::process::id().to_string()
    {
        let _ = fs::remove_file(path);
    }
}

/// `_write_bridge_target_files`: the app's view of the focused target.
pub fn write_bridge_target_files(cwd: &str, provider: &str, spool_dir: &str) {
    let settings = settings();
    for (path, value) in [
        (&settings.bridge_cwd_file, cwd),
        (&settings.bridge_provider_file, provider),
        (&settings.bridge_spool_file, spool_dir),
    ] {
        write_through_temporary(path, value);
    }
}

/// `_watchdog_restart_preserves_turns`: whether a same-session watchdog
/// restart is stopping or starting this bridge.
pub fn watchdog_restart_preserves_turns(stopping: bool) -> bool {
    let settings = settings();
    let session_id = &settings.provider_session_id;
    if session_id.is_empty() || Path::new(&settings.stop_requested_file).exists() {
        return false;
    }
    let Ok(text) = fs::read_to_string(&settings.watchdog_restart_file) else {
        return false;
    };
    let fields: Vec<&str> = text.split_whitespace().collect();
    if fields.first() != Some(&session_id.as_str()) {
        return false;
    }
    if !stopping {
        return true;
    }
    fields.get(1) == Some(&std::process::id().to_string().as_str())
}

/// `os.unlink(path)`, ignoring failure.
pub fn remove(path: &str) {
    let _ = fs::remove_file(path);
}

/// `os.path.exists(path)`.
pub fn exists(path: &str) -> bool {
    Path::new(path).exists()
}
