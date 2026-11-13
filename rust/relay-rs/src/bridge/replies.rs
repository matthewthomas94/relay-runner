//! Which foreground finals were delivered, which are in flight, when the PM
//! last traced a command, and the RR-460 missing-outcome watches
//! (`voice_bridge.py` from `_foreground_reply_delivered` to
//! `_mark_foreground_reply_delivered`).

use std::collections::BTreeSet;
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::Instant;

use super::ports::Speech;
use super::settings::settings;
use super::store::{read_json_file, relay_command_key};
use crate::json::{Dict, Value};
use crate::support::now;

type Key = (i64, String);

/// An insertion-ordered set: Python trims its sets by dropping fifty
/// arbitrary members; this drops the fifty oldest.
#[derive(Default)]
struct OrderedSet(Vec<Key>);

impl OrderedSet {
    fn contains(&self, key: &Key) -> bool {
        self.0.contains(key)
    }

    fn add(&mut self, key: Key) {
        if !self.contains(&key) {
            self.0.push(key);
        }
        if self.0.len() > 100 {
            self.0.drain(..50);
        }
    }
}

#[derive(Default)]
struct ReplyState {
    replied: OrderedSet,
    in_flight: BTreeSet<Key>,
    fallback: OrderedSet,
    pm_trace_at: Vec<(Key, Instant)>,
}

struct Watch {
    started_at: f64,
    signals: BTreeSet<String>,
}

#[derive(Default)]
struct WatchState {
    watches: Vec<(Key, Watch)>,
    failure_at: Option<f64>,
    failure_signal: String,
}

static REPLIES: LazyLock<Mutex<ReplyState>> = LazyLock::new(Mutex::default);
static WATCHES: LazyLock<Mutex<WatchState>> = LazyLock::new(Mutex::default);

fn replies() -> MutexGuard<'static, ReplyState> {
    REPLIES
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn watches() -> MutexGuard<'static, WatchState> {
    WATCHES
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn key(command: Option<&Dict>) -> Option<Key> {
    command.and_then(relay_command_key)
}

/// `_foreground_reply_delivered`.
pub fn foreground_reply_delivered(command: Option<&Dict>) -> bool {
    let Some(key) = key(command) else {
        return false;
    };
    let state = replies();
    state.replied.contains(&key) || state.in_flight.contains(&key)
}

/// `_reserve_foreground_reply_delivery`.
pub fn reserve_foreground_reply_delivery(command: Option<&Dict>) -> bool {
    let Some(key) = key(command) else {
        return false;
    };
    let mut state = replies();
    if state.replied.contains(&key) || state.in_flight.contains(&key) {
        return false;
    }
    state.in_flight.insert(key);
    true
}

/// `_finish_foreground_reply_delivery`.
pub fn finish_foreground_reply_delivery(command: Option<&Dict>, delivered: bool, fallback: bool) {
    let Some(key) = key(command) else {
        return;
    };
    let mut state = replies();
    state.in_flight.remove(&key);
    if delivered {
        if fallback {
            state.fallback.add(key);
        } else {
            state.replied.add(key);
        }
    }
}

/// `_foreground_fallback_delivered`.
pub fn foreground_fallback_delivered(command: Option<&Dict>) -> bool {
    key(command).is_some_and(|key| replies().fallback.contains(&key))
}

/// `_mark_foreground_reply_delivered`.
pub fn mark_foreground_reply_delivered(command: Option<&Dict>) {
    if let Some(key) = key(command) {
        replies().replied.add(key);
    }
}

/// `_note_pm_trace`.
pub fn note_pm_trace(command: Option<&Dict>) {
    let Some(key) = key(command) else {
        return;
    };
    let mut state = replies();
    state.pm_trace_at.retain(|(existing, _)| *existing != key);
    state.pm_trace_at.push((key, Instant::now()));
    if state.pm_trace_at.len() > 64 {
        state.pm_trace_at.remove(0);
    }
}

/// `_pm_trace_recent`.
pub fn pm_trace_recent(command: Option<&Dict>) -> bool {
    let Some(key) = key(command) else {
        return false;
    };
    let traced_at = replies()
        .pm_trace_at
        .iter()
        .find(|(existing, _)| *existing == key)
        .map(|(_, at)| *at);
    traced_at.is_some_and(|at| at.elapsed().as_secs_f64() < settings().trace_active_seconds)
}

/// `_note_daemon_fetch_failure`.
pub fn note_daemon_fetch_failure(error: &str) {
    let timed_out = error.to_lowercase().contains("timed out");
    let mut state = watches();
    state.failure_at = Some(now());
    state.failure_signal = if timed_out {
        "daemon_fetch_timed_out"
    } else {
        "daemon_fetch_failed"
    }
    .to_string();
}

/// `_watch_command_outcome`: track a voice command until it ends with or
/// without an outcome (RR-460).
pub fn watch_command_outcome(command: Option<&Dict>) {
    let Some(key) = key(command) else {
        return;
    };
    let mut state = watches();
    if !state.watches.iter().any(|(existing, _)| *existing == key) {
        state.watches.push((
            key,
            Watch {
                started_at: now(),
                signals: BTreeSet::new(),
            },
        ));
    }
    while state.watches.len() > 64 {
        state.watches.remove(0);
    }
}

/// `_note_outcome_signal`.
pub fn note_outcome_signal(command: Option<&Dict>, signal: &str) {
    let Some(key) = key(command) else {
        return;
    };
    let mut state = watches();
    if let Some((_, watch)) = state
        .watches
        .iter_mut()
        .find(|(existing, _)| *existing == key)
    {
        watch.signals.insert(signal.to_string());
    }
}

/// `_close_outcome_watch`: one `missing_outcome` event when the command
/// ended silently.
pub fn close_outcome_watch(command: Option<&Dict>, speech: &dyn Speech, ended_by: &str) -> bool {
    let Some(key) = key(command) else {
        return false;
    };
    let (watch, failure_at, failure_signal) = {
        let mut state = watches();
        let position = state
            .watches
            .iter()
            .position(|(existing, _)| *existing == key);
        let watch = position.map(|position| state.watches.remove(position).1);
        (watch, state.failure_at, state.failure_signal.clone())
    };
    let Some(watch) = watch else {
        return false;
    };
    if foreground_reply_delivered(command) || foreground_fallback_delivered(command) {
        return false;
    }
    let mut signals = watch.signals;
    if !signals.contains("hook_received") {
        signals.insert("hook_not_received".to_string());
    }
    if failure_at.unwrap_or(0.0) >= watch.started_at && failure_at.is_some() {
        signals.insert(failure_signal);
    }
    let reason = [
        "reply_helper_rejected",
        "hook_not_received",
        "daemon_fetch_timed_out",
        "daemon_fetch_failed",
    ]
    .into_iter()
    .find(|signal| signals.contains(*signal))
    .unwrap_or(ended_by)
    .to_string();
    signals.insert(ended_by.to_string());
    signals.remove("hook_received");
    let signals: Vec<String> = signals.into_iter().collect();
    speech.record_missing_outcome(key.0, &key.1, &reason, &signals)
}

/// `_sweep_outcome_watches`: close watches whose provider turn ended or
/// outlived the hard ceiling.
pub fn sweep_outcome_watches(speech: &dyn Speech, turns_path: &str, at: Option<f64>) {
    let at = at.unwrap_or_else(now);
    let watched: Vec<(Key, f64, bool)> = watches()
        .watches
        .iter()
        .map(|(key, watch)| {
            (
                key.clone(),
                watch.started_at,
                watch.signals.contains("hook_received"),
            )
        })
        .collect();
    if watched.is_empty() {
        return;
    }
    let ledger = read_json_file(turns_path);
    let records: Vec<Value> = ledger
        .get("records")
        .and_then(Value::as_list)
        .map(<[Value]>::to_vec)
        .unwrap_or_default();
    for (key, started_at, hook_received) in watched {
        if hook_received {
            continue;
        }
        let states: BTreeSet<String> = records
            .iter()
            .filter_map(Value::as_dict)
            .filter(|record| relay_command_key(record).as_ref() == Some(&key))
            .map(|record| record.string("state"))
            .collect();
        let ended_by = if !states.is_empty() && !states.contains("active") {
            "provider_turn_terminal"
        } else if at - started_at >= settings().hard_ceiling_seconds {
            "hard_ceiling"
        } else {
            continue;
        };
        let mut command = Dict::new();
        command.insert("relay_command_seq", key.0);
        command.insert("relay_command_id", key.1.as_str());
        close_outcome_watch(Some(&command), speech, ended_by);
    }
}
