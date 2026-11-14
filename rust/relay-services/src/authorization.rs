//! Port of `services/relay_authorization.py`, shared by the voice bridge
//! (RR-492) and the orchestrator daemon (RR-499).
//!
//! Conversational freshness and project-mutation authorization are separate:
//! `voice_command_state.json` names the newest turn for replies and speech,
//! while this ledger (`VOICE_COMMAND_AUTHORIZATION_FILE`) lists the project
//! mutations still authorized. The bridge registers each turn's grants and
//! revokes superseded ones ([`record_command_authorization`],
//! [`transfer_session_authorizations`]); the daemon validates and marks
//! mutations against the same file ([`authorization_exists`],
//! [`validate_and_mark_mutation`], [`mark_mutations_canceled`]). Both write it
//! exactly as Python's `json.dump(ledger, f, sort_keys=True)` writes it, under
//! the same `<ledger>.lock` `flock`. A daemon refusal is a `ValueError` with
//! Python's message, which the HTTP layer returns as a 400.

use std::collections::HashSet;
use std::fs::{self, File, OpenOptions, Permissions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::LazyLock;
use std::time::{SystemTime, UNIX_EPOCH};

use relay_intents::json::{self, Dict, Value};
use relay_intents::pattern::{self, Regex, compile};
use relay_intents::qualification::dispatch_forbidden;

use crate::{Error, Result};

pub const AUTHORIZATION_CONTRACT_VERSION: i64 = 1;
pub const AUTHORIZATION_LIMIT: usize = 32;
const SUPERSEDING_RELATIONSHIPS: [&str; 4] = ["replacement", "redirect", "interrupt", "cancel"];

static ADDITIVE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(also|as\s+well|too|in\s+addition|another|next|and\s+then)\b",
        true,
    )
});
static REDIRECT: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(actually|instead|rather|redirect|switch|change\s+that\s+to|make\s+that)\b",
        true,
    )
});
static NATURAL_CANCEL: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(cancel|stop|abort|scratch\s+that|never\s+mind|nevermind)\b",
        true,
    )
});
static TICKET_ID: LazyLock<Regex> =
    LazyLock::new(|| compile(r"\b(GEN-[A-Fa-f0-9]{16}|[A-Za-z][A-Za-z0-9]*-\d+)\b", false));

/// `command_relationship`: how a turn affects outstanding project-mutation
/// authority. Arguments are `str(value or "")` of the action's `kind`,
/// `reason` and `source_text`.
pub fn command_relationship(action_kind: &str, reason: &str, source_text: &str) -> &'static str {
    let kind = json::py_strip(action_kind);
    let control_reason = json::py_strip(reason).to_lowercase();
    match kind {
        "control" if control_reason == "interrupt" => "interrupt",
        "control" if control_reason == "cancel" => "cancel",
        "control" | "direct_action" => "control",
        "inspect_ticket" => "inspection",
        "create_ticket" | "update_ticket" | "dispatch_ticket" | "inline_work" => {
            if pattern::search(&NATURAL_CANCEL, source_text) {
                "cancel"
            } else if pattern::search(&REDIRECT, source_text) {
                "redirect"
            } else if pattern::search(&ADDITIVE, source_text) {
                "additive"
            } else {
                "replacement"
            }
        }
        _ => "conversation",
    }
}

fn strings(values: &[&str]) -> Value {
    Value::List(values.iter().map(|value| Value::from(*value)).collect())
}

fn mutation(kind: &str) -> Dict {
    let mut allowed = Dict::new();
    allowed.insert("kind", kind);
    allowed
}

fn orchestrator_action(action_kinds: &[&str], ticket_id: &str) -> Dict {
    let mut allowed = mutation("orchestrator_action");
    allowed.insert("action_kinds", strings(action_kinds));
    allowed.insert("ticket_id", ticket_id);
    allowed
}

fn dispatch_ticket(ticket_id: &str) -> Dict {
    let mut allowed = mutation("dispatch_ticket");
    allowed.insert("ticket_id", ticket_id);
    allowed
}

/// `allowed_mutations_for_metadata`: the mutation shapes a published Relay
/// command may start.
pub fn allowed_mutations_for_metadata(metadata: &Dict) -> Vec<Dict> {
    let action = metadata.text("action");
    let source_text = metadata.string("source_text");
    if dispatch_forbidden(&source_text) {
        // Drafting a ticket is not permission to start its implementation.
        // Keep the explicit no-dispatch constraint even when metadata says "task".
        let ticket_id = match metadata.truthy("ticket_id") {
            Some(value) => value.py_str().to_uppercase(),
            None => "*".to_string(),
        };
        return match action.as_str() {
            "create_ticket" => vec![orchestrator_action(
                &["create_ticket", "edit_ticket", "update_dependencies"],
                &ticket_id,
            )],
            "update_ticket" => vec![orchestrator_action(
                &["edit_ticket", "update_dependencies"],
                &ticket_id,
            )],
            _ => Vec::new(),
        };
    }
    let ticket_id = metadata.text("ticket_id").to_uppercase();
    let mut ticket_ids: Vec<String> = pattern::find_all(&TICKET_ID, &source_text)
        .into_iter()
        .map(str::to_uppercase)
        .collect();
    if !ticket_id.is_empty() && !ticket_ids.contains(&ticket_id) {
        ticket_ids.insert(0, ticket_id.clone());
    }
    let ticket_or_any = if ticket_id.is_empty() {
        "*"
    } else {
        &ticket_id
    };
    match action.as_str() {
        "dispatch_ticket" if ticket_ids.len() > 1 => {
            let mut allowed = mutation("dispatch_ticket");
            let ids = ticket_ids.into_iter().map(Value::from).collect::<Vec<_>>();
            allowed.insert("ticket_ids", ids);
            vec![allowed]
        }
        "dispatch_ticket" => vec![dispatch_ticket(ticket_or_any)],
        "create_ticket" => vec![
            orchestrator_action(
                &[
                    "create_ticket",
                    "edit_ticket",
                    "update_dependencies",
                    "request_worker",
                ],
                "*",
            ),
            dispatch_ticket("*"),
            mutation("spike_followup_accept"),
            mutation("orchestrator_command"),
        ],
        "update_ticket" => vec![
            orchestrator_action(
                &["edit_ticket", "update_dependencies", "request_worker"],
                ticket_or_any,
            ),
            dispatch_ticket(ticket_or_any),
            mutation("spike_followup_accept"),
            mutation("orchestrator_command"),
        ],
        _ => Vec::new(),
    }
}

// -- the ledger file ----------------------------------------------------------

/// `time.time()`.
fn now_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

/// `relay_command_key`: the command a metadata object or ledger record
/// names, an integer sequence and a non-empty, stripped id.
pub fn relay_command_key(command: &Dict) -> Option<(i64, String)> {
    let command_id = command.text("relay_command_id");
    if command_id.is_empty() {
        return None;
    }
    let command_seq = command.get("relay_command_seq")?.py_int()?;
    Some((command_seq, command_id))
}

/// The key of a route's separate `relay_command_seq` and `relay_command_id`.
fn command_key(relay_command_seq: &Value, relay_command_id: &Value) -> Option<(i64, String)> {
    let mut command = Dict::new();
    command.insert("relay_command_seq", relay_command_seq.clone());
    command.insert("relay_command_id", relay_command_id.clone());
    relay_command_key(&command)
}

/// `path` with `suffix` appended to its file name.
fn sibling(path: &Path, suffix: &str) -> std::path::PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    name.into()
}

/// `_authorization_ledger_lock`: an exclusive `flock` on `<ledger>.lock`,
/// released when this is dropped.
struct LedgerLock(File);

impl Drop for LedgerLock {
    fn drop(&mut self) {
        // SAFETY: the descriptor is open for as long as `self.0` lives.
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

fn lock_ledger(path: &Path) -> io::Result<LedgerLock> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let lock_path = sibling(path, ".lock");
    let file = OpenOptions::new()
        .read(true)
        .append(true)
        .create(true)
        .open(&lock_path)?;
    fs::set_permissions(&lock_path, Permissions::from_mode(0o600))?;
    loop {
        // SAFETY: `file` is an open descriptor.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
            return Ok(LedgerLock(file));
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

/// `_load_ledger`: the stored `updated_at` and the records that are objects.
fn load_ledger(path: &Path) -> (Value, Vec<Dict>) {
    let mut data = match fs::read(path)
        .ok()
        .and_then(|bytes| json::parse_bytes(&bytes))
    {
        Some(Value::Dict(data)) => data,
        _ => Dict::new(),
    };
    let records = match data.remove("authorizations") {
        Some(Value::List(items)) => items
            .into_iter()
            .filter_map(|item| match item {
                Value::Dict(record) => Some(record),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    };
    (data.remove("updated_at").unwrap_or(Value::Null), records)
}

/// The ledger object `_load_ledger` returns and the module writes.
fn ledger(updated_at: Value, records: Vec<Dict>) -> Dict {
    let mut ledger = Dict::new();
    ledger.insert("version", AUTHORIZATION_CONTRACT_VERSION);
    ledger.insert("updated_at", updated_at);
    ledger.insert(
        "authorizations",
        records.into_iter().map(Value::Dict).collect::<Vec<_>>(),
    );
    ledger
}

/// `_atomic_write_json`: key-sorted JSON through a temporary file named for
/// this process and thread.
fn atomic_write_json(path: &Path, payload: &Dict) -> io::Result<()> {
    // SAFETY: `pthread_self` has no preconditions; it is `threading.get_ident()`.
    let thread = unsafe { libc::pthread_self() } as usize;
    let temporary = sibling(path, &format!(".{}.{thread}.tmp", std::process::id()));
    let written = fs::write(
        &temporary,
        json::dumps_sorted(&Value::Dict(payload.clone())),
    )
    .and_then(|()| fs::rename(&temporary, path));
    let _ = fs::remove_file(&temporary);
    written
}

/// `_find_record`: the newest record of the command (and intent, if named).
fn find_record(records: &[Dict], key: &(i64, String), intent_id: Option<&str>) -> Option<usize> {
    records.iter().rposition(|record| {
        relay_command_key(record).as_ref() == Some(key)
            && intent_id.is_none_or(|intent_id| record.string("intent_id") == intent_id)
    })
}

fn is_active(record: &Dict) -> bool {
    record.string("status") == "active"
}

/// `_prune_records`: the newest inactive records and every active one, at
/// most `AUTHORIZATION_LIMIT` in all.
fn prune_records(records: Vec<Dict>) -> Vec<Dict> {
    let (active, inactive): (Vec<Dict>, Vec<Dict>) = records.into_iter().partition(is_active);
    let mut kept: Vec<Dict> = inactive
        .into_iter()
        .rev()
        .take(AUTHORIZATION_LIMIT)
        .rev()
        .chain(active)
        .collect();
    let excess = kept.len().saturating_sub(AUTHORIZATION_LIMIT);
    kept.drain(..excess);
    kept
}

/// `record.get("target") or record.get("ticket_id")`, upper-cased.
fn ticket_of(record: &Dict) -> String {
    let target = record.string("target");
    if target.is_empty() {
        record.string("ticket_id").to_uppercase()
    } else {
        target.to_uppercase()
    }
}

/// `record_command_authorization`: applies a turn's supersession
/// relationship to the ledger and registers its `allowed_mutations` (those of
/// `allowed_mutations_for_metadata` when `None`). An empty `relationship`
/// reads the metadata's `authorization_relationship`, else `conversation`.
///
/// `session_key` names the app-owned session spool the turn belongs to
/// (empty for manual single-session bridges). A turn only revokes records of
/// its own session, so `all_work` never preempts another session. `now` is
/// `time.time()` unless given. Returns the ledger as written.
pub fn record_command_authorization(
    path: impl AsRef<Path>,
    metadata: &Dict,
    relationship: &str,
    allowed_mutations: Option<Vec<Dict>>,
    session_key: &str,
    now: Option<f64>,
) -> io::Result<Dict> {
    let path = path.as_ref();
    let _lock = lock_ledger(path)?;
    let Some(key) = relay_command_key(metadata) else {
        let (updated_at, records) = load_ledger(path);
        return Ok(ledger(updated_at, records));
    };
    let now = now.unwrap_or_else(now_seconds);
    let fallback;
    let relationship = if relationship.is_empty() {
        fallback = metadata.string("authorization_relationship");
        if fallback.is_empty() {
            "conversation"
        } else {
            fallback.as_str()
        }
    } else {
        relationship
    };
    let allowed_mutations =
        allowed_mutations.unwrap_or_else(|| allowed_mutations_for_metadata(metadata));

    let (_, mut records) = load_ledger(path);
    let intent_id = metadata.text("intent_id");
    if SUPERSEDING_RELATIONSHIPS.contains(&relationship) {
        let scope = metadata.text("cancellation_scope");
        let target_ids: HashSet<String> = metadata
            .truthy("target_intent_ids")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .map(Value::py_str)
            .filter(|value| !value.is_empty())
            .collect();
        let target_ticket = ticket_of(metadata);
        let mut revoked_by = Dict::new();
        revoked_by.insert("relay_command_seq", key.0);
        revoked_by.insert("relay_command_id", key.1.as_str());
        revoked_by.insert("relationship", relationship);
        revoked_by.insert(
            "intent_id",
            (!intent_id.is_empty()).then_some(intent_id.as_str()),
        );
        for record in &mut records {
            if relay_command_key(record).as_ref() == Some(&key)
                && record.string("intent_id") == intent_id
            {
                continue;
            }
            if !is_active(record) || record.string("relay_session_key") != session_key {
                continue;
            }
            if scope == "item" || scope == "ticket" {
                let skip = if !target_ids.is_empty() {
                    !target_ids.contains(&record.string("intent_id"))
                } else {
                    target_ticket.is_empty() || ticket_of(record) != target_ticket
                };
                if skip {
                    continue;
                }
            }
            record.insert("status", "revoked");
            record.insert("revoked_at", now);
            record.insert("revoked_by", revoked_by.clone());
        }
    }

    if !allowed_mutations.is_empty() {
        let intent = (!intent_id.is_empty()).then_some(intent_id.as_str());
        let index = find_record(&records, &key, intent).unwrap_or_else(|| {
            let mut record = Dict::new();
            record.insert("relay_command_seq", key.0);
            record.insert("relay_command_id", key.1.as_str());
            record.insert("registered_at", now);
            record.insert("started_mutations", Vec::<Value>::new());
            record.insert("canceled_mutations", Vec::<Value>::new());
            records.push(record);
            records.len() - 1
        });
        let record = &mut records[index];
        record.insert("status", "active");
        record.insert("relationship", relationship);
        record.insert(
            "allowed_mutations",
            allowed_mutations
                .into_iter()
                .map(Value::Dict)
                .collect::<Vec<_>>(),
        );
        record.insert("updated_at", now);
        for field in [
            "intent_id",
            "within_turn_order",
            "target",
            "disposition",
            "cancellation_scope",
        ] {
            if let Some(value) = metadata.present(field) {
                record.insert(field, value.clone());
            }
        }
        if !session_key.is_empty() {
            record.insert("relay_session_key", session_key);
        }
    }

    let written = ledger(Value::Float(now), prune_records(records));
    atomic_write_json(path, &written)?;
    Ok(written)
}

/// `transfer_session_authorizations`: moves an ended session's active grants
/// to the session inheriting its work (an empty `to_session_key` makes them
/// key-less), so a queued command handed off keeps its bounds under the key
/// the receiving provider presents. Returns how many moved.
pub fn transfer_session_authorizations(
    path: impl AsRef<Path>,
    from_session_key: &str,
    to_session_key: &str,
    now: Option<f64>,
) -> io::Result<usize> {
    let path = path.as_ref();
    let _lock = lock_ledger(path)?;
    if from_session_key.is_empty() || from_session_key == to_session_key {
        return Ok(0);
    }
    let now = now.unwrap_or_else(now_seconds);
    let (_, mut records) = load_ledger(path);
    let mut moved = 0;
    for record in &mut records {
        if !is_active(record) || record.string("relay_session_key") != from_session_key {
            continue;
        }
        if to_session_key.is_empty() {
            record.remove("relay_session_key");
        } else {
            record.insert("relay_session_key", to_session_key);
        }
        record.insert("updated_at", now);
        moved += 1;
    }
    if moved > 0 {
        atomic_write_json(path, &ledger(Value::Float(now), records))?;
    }
    Ok(moved)
}

// -- the daemon's half ---------------------------------------------------------

/// `_session_records`: a keyed request may only use records registered for
/// its own session. Indices into `records`.
fn session_records(records: &[Dict], session_key: &str) -> Vec<usize> {
    (0..records.len())
        .filter(|&index| {
            session_key.is_empty() || records[index].string("relay_session_key") == session_key
        })
        .collect()
}

/// `authorization_exists`: whether the command registered any record (in
/// `session_key`'s session when one is given).
pub fn authorization_exists(
    path: impl AsRef<Path>,
    relay_command_seq: &Value,
    relay_command_id: &Value,
    session_key: &str,
) -> bool {
    let Some(key) = command_key(relay_command_seq, relay_command_id) else {
        return false;
    };
    let (_, records) = load_ledger(path.as_ref());
    session_records(&records, session_key)
        .into_iter()
        .any(|index| relay_command_key(&records[index]).as_ref() == Some(&key))
}

/// `_ticket_allowed`.
fn ticket_allowed(allowed: &Dict, ticket_id: &str) -> bool {
    if let Some(Value::List(ticket_ids)) = allowed.get("ticket_ids") {
        return ticket_ids.iter().any(|value| {
            let text = json::py_strip(&value.py_str()).to_uppercase();
            !text.is_empty() && text == ticket_id
        });
    }
    let allowed_ticket = allowed.text("ticket_id").to_uppercase();
    allowed_ticket.is_empty() || allowed_ticket == "*" || allowed_ticket == ticket_id
}

/// `mutation_allowed`: whether one of the record's `allowed_mutations`
/// covers the mutation's kind, action kind and ticket.
pub fn mutation_allowed(record: &Dict, mutation: &Dict) -> bool {
    let kind = mutation.text("kind");
    let action_kind = mutation.text("action_kind");
    let ticket_id = mutation.text("ticket_id").to_uppercase();
    let Some(allowed_mutations) = record.truthy("allowed_mutations").and_then(Value::as_list)
    else {
        return false;
    };
    allowed_mutations
        .iter()
        .filter_map(Value::as_dict)
        .any(|allowed| {
            if allowed.text("kind") != kind {
                return false;
            }
            if let Some(Value::List(action_kinds)) = allowed.get("action_kinds")
                && !action_kinds
                    .iter()
                    .any(|value| value.py_str() == action_kind)
            {
                return false;
            }
            ticket_id.is_empty() || ticket_allowed(allowed, &ticket_id)
        })
}

/// `mutation_fingerprint`: the identifying fields, as key-sorted JSON.
pub fn mutation_fingerprint(mutation: &Dict) -> String {
    let mut kept = Dict::new();
    for key in [
        "kind",
        "action_kind",
        "ticket_id",
        "action_index",
        "request_id",
    ] {
        if let Some(value) = mutation.present(key) {
            kept.insert(key, value.clone());
        }
    }
    json::dumps_sorted(&Value::Dict(kept))
}

fn fingerprints(record: &Dict, field: &str) -> Vec<String> {
    record
        .get(field)
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .filter_map(Value::as_dict)
        .map(|item| item.string("fingerprint"))
        .collect()
}

/// `record.setdefault(field, []).append(item)`: an existing key keeps its
/// place, a new one goes last.
fn append_to(record: &mut Dict, field: &str, item: Dict) {
    let mut items = match record.get(field) {
        Some(Value::List(items)) => items.clone(),
        _ => Vec::new(),
    };
    items.push(Value::Dict(item));
    record.insert(field, Value::List(items));
}

/// `validate_and_mark_mutation`: validates an active authorization of the
/// command (and `relay_intent_id`, when not empty) for `mutation`, in
/// `session_key`'s session when one is given, and marks the mutation
/// started. Returns the record as written. `now` is `time.time()` unless
/// given.
pub fn validate_and_mark_mutation(
    path: impl AsRef<Path>,
    relay_command_seq: &Value,
    relay_command_id: &Value,
    mutation: &Dict,
    relay_intent_id: &str,
    session_key: &str,
    now: Option<f64>,
) -> Result<Dict> {
    let path = path.as_ref();
    let _lock = lock_ledger(path)?;
    let Some(key) = command_key(relay_command_seq, relay_command_id) else {
        return Err(Error::value(
            "stale Relay command: missing mutation authorization metadata",
        ));
    };
    let now = now.unwrap_or_else(now_seconds);
    let (_, mut records) = load_ledger(path);
    let matching: Vec<usize> = session_records(&records, session_key)
        .into_iter()
        .rev()
        .filter(|&index| {
            let record = &records[index];
            relay_command_key(record).as_ref() == Some(&key)
                && (relay_intent_id.is_empty() || record.string("intent_id") == relay_intent_id)
        })
        .collect();
    let chosen = matching
        .iter()
        .copied()
        .find(|&index| is_active(&records[index]) && mutation_allowed(&records[index], mutation))
        .or_else(|| matching.first().copied());
    let Some(index) = chosen else {
        return Err(Error::value(
            "stale Relay command: no mutation authorization was registered",
        ));
    };
    let record = &mut records[index];
    if !is_active(record) {
        let relationship = record
            .get("revoked_by")
            .and_then(Value::as_dict)
            .map(|revoked_by| revoked_by.string("relationship"))
            .filter(|relationship| !relationship.is_empty())
            .unwrap_or_else(|| "newer command".to_string());
        return Err(Error::value(format!(
            "stale Relay command: mutation authorization was revoked by a newer {relationship} turn"
        )));
    }
    if !mutation_allowed(record, mutation) {
        return Err(Error::value(
            "Relay command is not authorized for this mutation",
        ));
    }
    let fingerprint = mutation_fingerprint(mutation);
    if fingerprints(record, "started_mutations").contains(&fingerprint) {
        return Err(Error::value("replayed Relay mutation authorization"));
    }
    let mut started = Dict::new();
    started.insert("fingerprint", fingerprint);
    started.insert("mutation", mutation.clone());
    started.insert("started_at", now);
    append_to(record, "started_mutations", started);
    record.insert("updated_at", now);
    let record = record.clone();
    atomic_write_json(path, &ledger(Value::Float(now), records))?;
    Ok(record)
}

/// `mark_mutations_canceled`: records each mutation the command will not
/// start, once per fingerprint already recorded, with `reason`. Nothing
/// changes when the command has no record.
pub fn mark_mutations_canceled(
    path: impl AsRef<Path>,
    relay_command_seq: &Value,
    relay_command_id: &Value,
    mutations: &[Dict],
    reason: &str,
    now: Option<f64>,
) -> Result<()> {
    let path = path.as_ref();
    let _lock = lock_ledger(path)?;
    let Some(key) = command_key(relay_command_seq, relay_command_id) else {
        return Ok(());
    };
    if mutations.is_empty() {
        return Ok(());
    }
    let now = now.unwrap_or_else(now_seconds);
    let (_, mut records) = load_ledger(path);
    let Some(index) = find_record(&records, &key, None) else {
        return Ok(());
    };
    let record = &mut records[index];
    let existing = fingerprints(record, "canceled_mutations");
    if record.get("canceled_mutations").is_none() {
        record.insert("canceled_mutations", Value::List(Vec::new()));
    }
    for mutation in mutations {
        let fingerprint = mutation_fingerprint(mutation);
        if existing.contains(&fingerprint) {
            continue;
        }
        let mut canceled = Dict::new();
        canceled.insert("fingerprint", fingerprint);
        canceled.insert("mutation", mutation.clone());
        canceled.insert("canceled_at", now);
        canceled.insert("reason", reason);
        append_to(record, "canceled_mutations", canceled);
    }
    record.insert("updated_at", now);
    atomic_write_json(path, &ledger(Value::Float(now), records))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use relay_intents::json::parse;

    fn dict(text: &str) -> Dict {
        parse(text).unwrap().as_dict().unwrap().clone()
    }

    fn allowed(text: &str) -> String {
        let mutations = allowed_mutations_for_metadata(&dict(text));
        json::dumps(&Value::List(
            mutations.into_iter().map(Value::Dict).collect(),
        ))
    }

    struct Ledger {
        root: String,
        path: String,
    }

    impl Ledger {
        fn new(name: &str) -> Self {
            let root = format!(
                "{}/relay-authorization-{name}-{}",
                std::env::temp_dir().display(),
                std::process::id()
            );
            let _ = fs::remove_dir_all(&root);
            let path = format!("{root}/sub/auth.json");
            Self { root, path }
        }

        fn text(&self) -> String {
            fs::read_to_string(&self.path).unwrap()
        }

        fn records(&self) -> Vec<Dict> {
            load_ledger(Path::new(&self.path)).1
        }

        fn record(
            &self,
            metadata: &str,
            relationship: &str,
            allowed: Option<Vec<Dict>>,
            key: &str,
            now: f64,
        ) {
            record_command_authorization(
                &self.path,
                &dict(metadata),
                relationship,
                allowed,
                key,
                Some(now),
            )
            .unwrap();
        }
    }

    impl Drop for Ledger {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn relationships_follow_the_action_and_its_wording() {
        let cases = [
            (("control", "interrupt", ""), "interrupt"),
            (("control", " Cancel ", ""), "cancel"),
            (("control", "stop", ""), "control"),
            (("inspect_ticket", "", ""), "inspection"),
            (("conversation", "", "cancel"), "conversation"),
            (("direct_action", "", ""), "control"),
            (
                ("create_ticket", "", "scratch that, make a ticket"),
                "cancel",
            ),
            (
                ("update_ticket", "", "actually change that to RR-3"),
                "redirect",
            ),
            (("dispatch_ticket", "", "also dispatch RR-4"), "additive"),
            (("inline_work", "", "fix the bug"), "replacement"),
            (("", "", "stop"), "conversation"),
            (("weird", "", ""), "conversation"),
        ];
        for ((kind, reason, text), expected) in cases {
            assert_eq!(
                command_relationship(kind, reason, text),
                expected,
                "{kind} {text}"
            );
        }
    }

    #[test]
    fn allowed_mutations_match_python() {
        // Each expectation is `json.dumps(allowed_mutations_for_metadata(...))`.
        let cases = [
            (
                r#"{"action": "dispatch_ticket", "ticket_id": "rr-1", "source_text": "dispatch rr-1"}"#,
                r#"[{"kind": "dispatch_ticket", "ticket_id": "RR-1"}]"#,
            ),
            (
                r#"{"action": "dispatch_ticket", "source_text": "dispatch RR-1 and rr-2"}"#,
                r#"[{"kind": "dispatch_ticket", "ticket_ids": ["RR-1", "RR-2"]}]"#,
            ),
            (
                r#"{"action": "dispatch_ticket", "ticket_id": "RR-9", "source_text": "dispatch RR-1 and GEN-0123456789abcdef"}"#,
                r#"[{"kind": "dispatch_ticket", "ticket_ids": ["RR-9", "RR-1", "GEN-0123456789ABCDEF"]}]"#,
            ),
            (
                r#"{"action": "dispatch_ticket", "source_text": "dispatch it"}"#,
                r#"[{"kind": "dispatch_ticket", "ticket_id": "*"}]"#,
            ),
            (
                r#"{"action": " create_ticket ", "source_text": "make a ticket for the login bug"}"#,
                r#"[{"kind": "orchestrator_action", "action_kinds": ["create_ticket", "edit_ticket", "update_dependencies", "request_worker"], "ticket_id": "*"}, {"kind": "dispatch_ticket", "ticket_id": "*"}, {"kind": "spike_followup_accept"}, {"kind": "orchestrator_command"}]"#,
            ),
            (
                r#"{"action": "update_ticket", "ticket_id": " rr-5 ", "source_text": "update it"}"#,
                r#"[{"kind": "orchestrator_action", "action_kinds": ["edit_ticket", "update_dependencies", "request_worker"], "ticket_id": "RR-5"}, {"kind": "dispatch_ticket", "ticket_id": "RR-5"}, {"kind": "spike_followup_accept"}, {"kind": "orchestrator_command"}]"#,
            ),
            (
                r#"{"action": "create_ticket", "ticket_id": "rr-7", "source_text": "create a ticket but don't dispatch it"}"#,
                r#"[{"kind": "orchestrator_action", "action_kinds": ["create_ticket", "edit_ticket", "update_dependencies"], "ticket_id": "RR-7"}]"#,
            ),
            (
                r#"{"action": "update_ticket", "source_text": "update RR-2 but do not dispatch it"}"#,
                r#"[{"kind": "orchestrator_action", "action_kinds": ["edit_ticket", "update_dependencies"], "ticket_id": "*"}]"#,
            ),
            (
                r#"{"action": "dispatch_ticket", "source_text": "dispatch RR-2, don't dispatch it"}"#,
                "[]",
            ),
            (
                r#"{"action": "conversation", "source_text": "what is RR-2"}"#,
                "[]",
            ),
        ];
        for (metadata, expected) in cases {
            assert_eq!(allowed(metadata), expected, "{metadata}");
        }
    }

    /// The ledger the Python module writes for the same calls, byte for byte.
    #[test]
    fn the_ledger_is_written_as_python_writes_it() {
        let ledger = Ledger::new("golden");
        ledger.record(
            r#"{"relay_command_seq": 10, "relay_command_id": "cmd-ticket", "intent_id": "cmd-ticket:item:1",
                "within_turn_order": 1, "target": "login", "action": "create_ticket",
                "source_text": "create a ticket for login", "disposition": null, "cancellation_scope": "none"}"#,
            "",
            None,
            "session-a",
            100.25,
        );
        let other = dict(
            r#"{"relay_command_seq": "11", "relay_command_id": "cmd-other", "intent_id": "cmd-other:item:1",
                "action": "dispatch_ticket", "ticket_id": "RR-4", "source_text": "dispatch RR-4"}"#,
        );
        record_command_authorization(
            &ledger.path,
            &other,
            "replacement",
            Some(allowed_mutations_for_metadata(&other)),
            "session-b",
            Some(101.5),
        )
        .unwrap();
        ledger.record(
            r#"{"relay_command_seq": 12, "relay_command_id": "cmd-q", "action": "conversation",
                "source_text": "what is up", "authorization_relationship": "conversation"}"#,
            "conversation",
            Some(Vec::new()),
            "session-a",
            102.0,
        );
        // An item-scoped redirect whose target is not in the ledger revokes nothing.
        ledger.record(
            r#"{"relay_command_seq": 13, "relay_command_id": "cmd-item", "intent_id": "cmd-item:item:1",
                "cancellation_scope": "item", "target_intent_ids": ["nope"]}"#,
            "redirect",
            Some(Vec::new()),
            "session-a",
            103.0,
        );
        ledger.record(
            r#"{"relay_command_seq": 14, "relay_command_id": "cmd-stop", "intent_id": "cmd-stop:item:1",
                "cancellation_scope": "all_work", "authorization_relationship": "redirect"}"#,
            "",
            Some(Vec::new()),
            "session-a",
            104.125,
        );
        let ticket = r#"{"allowed_mutations": [{"action_kinds": ["create_ticket", "edit_ticket", "update_dependencies", "request_worker"], "kind": "orchestrator_action", "ticket_id": "*"}, {"kind": "dispatch_ticket", "ticket_id": "*"}, {"kind": "spike_followup_accept"}, {"kind": "orchestrator_command"}], "canceled_mutations": [], "cancellation_scope": "none", "intent_id": "cmd-ticket:item:1", "registered_at": 100.25, "relationship": "conversation", "relay_command_id": "cmd-ticket", "relay_command_seq": 10, "relay_session_key": "session-a", "revoked_at": 104.125, "revoked_by": {"intent_id": "cmd-stop:item:1", "relationship": "redirect", "relay_command_id": "cmd-stop", "relay_command_seq": 14}, "started_mutations": [], "status": "revoked", "target": "login", "updated_at": 100.25, "within_turn_order": 1}"#;
        assert_eq!(
            ledger.text(),
            format!(
                r#"{{"authorizations": [{ticket}, {{"allowed_mutations": [{{"kind": "dispatch_ticket", "ticket_id": "RR-4"}}], "canceled_mutations": [], "intent_id": "cmd-other:item:1", "registered_at": 101.5, "relationship": "replacement", "relay_command_id": "cmd-other", "relay_command_seq": 11, "relay_session_key": "session-b", "started_mutations": [], "status": "active", "updated_at": 101.5}}], "updated_at": 104.125, "version": 1}}"#
            )
        );

        assert_eq!(
            transfer_session_authorizations(&ledger.path, "session-b", "", Some(105.0)).unwrap(),
            1
        );
        assert_eq!(
            ledger.text(),
            format!(
                r#"{{"authorizations": [{ticket}, {{"allowed_mutations": [{{"kind": "dispatch_ticket", "ticket_id": "RR-4"}}], "canceled_mutations": [], "intent_id": "cmd-other:item:1", "registered_at": 101.5, "relationship": "replacement", "relay_command_id": "cmd-other", "relay_command_seq": 11, "started_mutations": [], "status": "active", "updated_at": 105.0}}], "updated_at": 105.0, "version": 1}}"#
            )
        );
        let written = ledger.text();
        assert_eq!(
            transfer_session_authorizations(&ledger.path, "session-b", "session-c", Some(106.0))
                .unwrap(),
            0
        );
        // A command without an identity changes nothing.
        let unchanged = record_command_authorization(
            &ledger.path,
            &dict(r#"{"relay_command_id": "x"}"#),
            "cancel",
            None,
            "",
            Some(1.0),
        )
        .unwrap();
        assert_eq!(json::dumps_sorted(&Value::Dict(unchanged)), written);
        assert_eq!(ledger.text(), written);
        let lock = fs::metadata(format!("{}.lock", ledger.path)).unwrap();
        assert_eq!(lock.permissions().mode() & 0o777, 0o600);
        let mut names: Vec<String> = fs::read_dir(format!("{}/sub", ledger.root))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, ["auth.json", "auth.json.lock"]);
    }

    #[test]
    fn item_scope_revokes_only_its_target_intent() {
        let ledger = Ledger::new("item");
        for (order, target) in [(1, "login"), (2, "search")] {
            ledger.record(
                &format!(
                    r#"{{"relay_command_seq": 1, "relay_command_id": "multi-item",
                        "intent_id": "multi-item:item:{order}", "within_turn_order": {order},
                        "target": "{target}", "action": "create_ticket", "source_text": "fix {target}"}}"#
                ),
                "additive",
                None,
                "",
                f64::from(order),
            );
        }
        ledger.record(
            r#"{"relay_command_seq": 2, "relay_command_id": "cancel-login",
                "intent_id": "cancel-login:item:1", "cancellation_scope": "item",
                "target_intent_ids": ["multi-item:item:1"]}"#,
            "redirect",
            Some(Vec::new()),
            "",
            3.0,
        );
        let statuses: Vec<(String, String)> = ledger
            .records()
            .iter()
            .map(|record| (record.string("intent_id"), record.string("status")))
            .collect();
        assert_eq!(
            statuses,
            [
                ("multi-item:item:1".to_string(), "revoked".to_string()),
                ("multi-item:item:2".to_string(), "active".to_string()),
            ]
        );
        // A ticket scope without intent ids matches on the record's target.
        ledger.record(
            r#"{"relay_command_seq": 3, "relay_command_id": "cancel-search",
                "cancellation_scope": "ticket", "target": "Search"}"#,
            "cancel",
            Some(Vec::new()),
            "",
            4.0,
        );
        assert!(ledger.records().iter().all(|record| !is_active(record)));
    }

    #[test]
    fn a_turn_revokes_only_its_own_sessions_grants() {
        let ledger = Ledger::new("sessions");
        for (seq, key) in [(10, "session-a"), (11, "session-b"), (12, "")] {
            ledger.record(
                &format!(
                    r#"{{"relay_command_seq": {seq}, "relay_command_id": "cmd-{seq}",
                        "action": "dispatch_ticket", "ticket_id": "RR-1", "source_text": "dispatch RR-1"}}"#
                ),
                "additive",
                None,
                key,
                f64::from(seq),
            );
        }
        ledger.record(
            r#"{"relay_command_seq": 13, "relay_command_id": "cancel-b", "cancellation_scope": "all_work"}"#,
            "cancel",
            Some(Vec::new()),
            "session-b",
            13.0,
        );
        let statuses = |ledger: &Ledger| -> Vec<(String, String)> {
            ledger
                .records()
                .iter()
                .map(|r| (r.string("relay_command_id"), r.string("status")))
                .collect()
        };
        // Pruning lists inactive records first, as Python's does.
        let expected = [
            ("cmd-11", "revoked"),
            ("cmd-10", "active"),
            ("cmd-12", "active"),
        ];
        assert_eq!(
            statuses(&ledger),
            expected.map(|(id, status)| (id.to_string(), status.to_string()))
        );
        let revoked = &ledger.records()[0];
        let revoked_by = revoked.get("revoked_by").and_then(Value::as_dict).unwrap();
        assert_eq!(revoked_by.string("relationship"), "cancel");
        assert!(matches!(revoked_by.get("intent_id"), Some(Value::Null)));
        // A re-registered command keeps its record and its registration time.
        ledger.record(
            r#"{"relay_command_seq": 10, "relay_command_id": "cmd-10", "action": "dispatch_ticket",
                "ticket_id": "RR-1", "source_text": "dispatch RR-1"}"#,
            "replacement",
            None,
            "session-a",
            20.0,
        );
        assert_eq!(
            statuses(&ledger),
            expected.map(|(id, status)| (id.to_string(), status.to_string()))
        );
        let records = ledger.records();
        assert_eq!(
            records[1].get("registered_at").unwrap().py_float(),
            Some(10.0)
        );
        assert_eq!(records[1].string("relationship"), "replacement");
    }

    #[test]
    fn pruning_keeps_every_active_grant_before_old_revocations() {
        let ledger = Ledger::new("prune");
        for seq in 0..40 {
            ledger.record(
                &format!(r#"{{"relay_command_seq": {seq}, "relay_command_id": "cmd-{seq}", "action": "create_ticket"}}"#),
                "replacement",
                None,
                "",
                f64::from(seq),
            );
        }
        let records = ledger.records();
        assert_eq!(records.len(), AUTHORIZATION_LIMIT);
        // Each replacement revoked its predecessor: 31 revocations, then the one grant.
        assert_eq!(records.last().unwrap().string("relay_command_id"), "cmd-39");
        assert!(is_active(records.last().unwrap()));
        assert_eq!(records[0].string("relay_command_id"), "cmd-8");
        assert_eq!(records.iter().filter(|record| is_active(record)).count(), 1);
    }
}
