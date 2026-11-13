//! Context diagnostics: one line per lifecycle event recording the native
//! context size and the automatic-compaction attempt it belongs to.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

use crate::json::{self, Dict, Value, py_strip};
use crate::support;

use super::Event;

const TRANSCRIPT_TAIL_BYTES: u64 = 2 * 1024 * 1024;
const EVENTS_TAIL_BYTES: u64 = 256 * 1024;

fn nonnegative_int(value: Option<&Value>) -> Option<i64> {
    value
        .and_then(Value::py_int_not_bool)
        .filter(|number| *number >= 0)
}

/// `os.path.expanduser` for the current user.
fn expand_user(path: &str) -> String {
    match (path.strip_prefix('~'), std::env::var("HOME")) {
        (Some(rest), Ok(home)) if rest.is_empty() || rest.starts_with('/') => {
            format!("{}{rest}", home.trim_end_matches('/'))
        }
        _ => path.to_string(),
    }
}

/// The last `max_bytes` of a JSON-lines file, without the line the cut may
/// have split. Nothing is kept beyond the caller's scan.
fn read_tail(path: &str, max_bytes: u64) -> Option<Vec<u8>> {
    if path.is_empty() {
        return None;
    }
    let mut file = File::open(expand_user(path)).ok()?;
    let offset = file.metadata().ok()?.len().saturating_sub(max_bytes);
    file.seek(SeekFrom::Start(offset)).ok()?;
    let mut raw = Vec::new();
    file.take(max_bytes).read_to_end(&mut raw).ok()?;
    if offset > 0 {
        // Python's `bytes.splitlines` ends a line at "\n", "\r" or "\r\n".
        let first_end = raw.iter().position(|byte| matches!(byte, b'\n' | b'\r'))?;
        let crlf = raw[first_end] == b'\r' && raw.get(first_end + 1) == Some(&b'\n');
        raw.drain(..first_end + 1 + usize::from(crlf));
    }
    Some(raw)
}

/// The objects in `tail`, newest first; lines that are not a JSON object are
/// skipped.
fn recent_objects(tail: &[u8]) -> impl Iterator<Item = Dict> {
    tail.rsplit(|byte| matches!(byte, b'\n' | b'\r'))
        .filter_map(|line| match json::parse_bytes(line) {
            Some(Value::Dict(record)) => Some(record),
            _ => None,
        })
}

fn is(record: &Dict, key: &str, text: &str) -> bool {
    record.get(key).is_some_and(|value| value.is_str(text))
}

/// Codex: `info.last_token_usage.total_tokens` of the newest `token_count`,
/// as the payload of an `event_msg` or as a bare record.
fn codex_active_context_tokens(tail: &[u8]) -> Option<i64> {
    for record in recent_objects(tail) {
        let payload = if is(&record, "type", "event_msg") {
            match record.get("payload").and_then(Value::as_dict) {
                Some(payload) => payload,
                None => continue,
            }
        } else {
            &record
        };
        if !is(payload, "type", "token_count") {
            continue;
        }
        let usage = payload
            .get("info")
            .and_then(Value::as_dict)
            .and_then(|info| info.get("last_token_usage"))
            .and_then(Value::as_dict);
        if let Some(usage) = usage {
            return nonnegative_int(usage.get("total_tokens"));
        }
    }
    None
}

/// Claude: the newest of a compact boundary's `postTokens` or a main-chain
/// assistant message's input plus cache tokens.
fn claude_active_context_tokens(tail: &[u8]) -> Option<i64> {
    for record in recent_objects(tail) {
        if is(&record, "type", "system") && is(&record, "subtype", "compact_boundary") {
            let post_tokens = record
                .get("compactMetadata")
                .and_then(Value::as_dict)
                .and_then(|metadata| nonnegative_int(metadata.get("postTokens")));
            if post_tokens.is_some() {
                return post_tokens;
            }
        }
        let sidechain = matches!(record.get("isSidechain"), Some(Value::Bool(true)));
        if !is(&record, "type", "assistant") || sidechain {
            continue;
        }
        let usage = record
            .get("message")
            .and_then(Value::as_dict)
            .and_then(|message| message.get("usage"))
            .and_then(Value::as_dict);
        let Some(usage) = usage else {
            continue;
        };
        let components = [
            "input_tokens",
            "cache_creation_input_tokens",
            "cache_read_input_tokens",
        ]
        .map(|field| nonnegative_int(usage.get(field)));
        if components.iter().any(Option::is_some) {
            return Some(components.iter().flatten().sum());
        }
    }
    None
}

fn native_active_context_tokens(event: &Event, provider: Option<&str>) -> Option<i64> {
    let parser: fn(&[u8]) -> Option<i64> = match provider {
        Some("codex") => codex_active_context_tokens,
        Some("claude") => claude_active_context_tokens,
        _ => return None,
    };
    let transcript_path = event.payload.text("transcript_path");
    parser(&read_tail(&transcript_path, TRANSCRIPT_TAIL_BYTES)?)
}

/// Appends one compact, key-sorted JSON line, mode 0600. A path that cannot
/// be written is ignored: diagnostics never fail the hook.
pub fn append_session_event(event: &Dict, path: &str) {
    if path.is_empty() {
        return;
    }
    let line = json::dumps_compact_sorted(&Value::Dict(event.clone())) + "\n";
    let opened = OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .open(path);
    if let Ok(mut file) = opened
        && file.write_all(line.as_bytes()).is_ok()
    {
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
}

fn same_session(record: &Dict, provider: &str, session_id: &str) -> bool {
    is(record, "provider", provider) && is(record, "session_id", session_id)
}

/// The attempt a compaction event belongs to: PreCompact opens the next one.
fn compaction_attempt_number(tail: &[u8], provider: &str, session_id: &str, advance: bool) -> i64 {
    let latest = recent_objects(tail)
        .find(|record| {
            is(record, "stage", "compaction_attempt") && same_session(record, provider, session_id)
        })
        .and_then(|record| nonnegative_int(record.get("attempt")))
        .unwrap_or(0);
    if advance { latest + 1 } else { latest.max(1) }
}

/// The attempt still waiting for confirmation, when the newest compaction
/// record of this session is an unconfirmed one.
fn pending_unconfirmed_attempt(tail: &[u8], provider: &str, session_id: &str) -> Option<i64> {
    for record in recent_objects(tail) {
        if !same_session(&record, provider, session_id) {
            continue;
        }
        match record.get("stage").and_then(Value::as_str) {
            Some("compaction_unconfirmed") => return nonnegative_int(record.get("attempt")),
            Some("compaction_attempt" | "compaction_confirmed") => return None,
            _ => {}
        }
    }
    None
}

pub fn record_diagnostic(event: &Event, name: &str) {
    if !matches!(
        name,
        "UserPromptSubmit" | "Stop" | "StopFailure" | "PreCompact" | "PostCompact"
    ) {
        return;
    }
    let settings = event.settings;
    let events_path = &settings.compaction_events_path;
    let provider = event.provider(None);
    let provider_name = provider.as_deref().unwrap_or("unknown");
    let active_tokens = native_active_context_tokens(event, provider.as_deref());
    let threshold = settings.threshold_tokens;
    let below_threshold = active_tokens.is_some_and(|tokens| tokens < threshold);
    let threshold_state = match active_tokens {
        None => "unknown",
        Some(tokens) if tokens < threshold => "below",
        Some(tokens) if tokens == threshold => "exact",
        Some(_) => "above",
    };
    let session_id = event.session_id();
    let events_tail = || read_tail(events_path, EVENTS_TAIL_BYTES).unwrap_or_default();

    let mut attempt = matches!(name, "PreCompact" | "PostCompact" | "StopFailure").then(|| {
        compaction_attempt_number(
            &events_tail(),
            provider_name,
            &session_id,
            name == "PreCompact",
        )
    });
    let post_compact_confirmed = name == "PostCompact" && below_threshold;
    let delayed_confirmation_attempt = (matches!(name, "UserPromptSubmit" | "Stop")
        && below_threshold)
        .then(|| pending_unconfirmed_attempt(&events_tail(), provider_name, &session_id))
        .flatten();
    let delayed = delayed_confirmation_attempt.is_some();
    if delayed {
        attempt = delayed_confirmation_attempt;
    }
    let (stage, outcome) = match name {
        "UserPromptSubmit" | "Stop" if delayed => ("compaction_confirmed", "confirmed"),
        "UserPromptSubmit" => ("active_context_observed", "busy"),
        "Stop" => ("active_context_observed", "idle"),
        "StopFailure" => ("provider_turn_failed", "failed"),
        "PreCompact" => ("compaction_attempt", "started"),
        _ if post_compact_confirmed => ("compaction_confirmed", "confirmed"),
        _ => ("compaction_unconfirmed", "unconfirmed"),
    };
    let failure_reason: Value = if name == "PostCompact" && !post_compact_confirmed {
        "native_context_not_reduced".into()
    } else {
        event
            .payload
            .get("error")
            .and_then(Value::as_str)
            .filter(|reason| !reason.is_empty())
            .map(|reason| reason.chars().take(80).collect::<String>())
            .into()
    };
    let trigger = Some(py_strip(&event.payload.string("trigger")).to_lowercase())
        .filter(|trigger| !trigger.is_empty());

    let mut record = Dict::new();
    record.insert("timestamp", support::utc_timestamp(event.now));
    record.insert("stage", stage);
    record.insert("outcome", outcome);
    record.insert("provider", provider_name);
    record.insert("session_id", session_id);
    record.insert("native_active_context_tokens", active_tokens);
    record.insert("threshold_tokens", threshold);
    record.insert("threshold_state", threshold_state);
    record.insert(
        "idle_boundary",
        if name == "UserPromptSubmit" {
            "busy"
        } else {
            "provider_native"
        },
    );
    record.insert("attempt", attempt);
    record.insert("trigger", trigger);
    record.insert("confirmation", post_compact_confirmed || delayed);
    record.insert("failure_reason", failure_reason);
    append_session_event(&record, events_path);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_reads_the_newest_token_count_with_usage() {
        let tail = br#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}
not json
{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}
{"type":"event_msg","payload":{"type":"token_count","info":null}}
{"type":"event_msg","payload":"token_count"}
[1, 2]
"#;
        assert_eq!(codex_active_context_tokens(tail), Some(200));
        assert_eq!(codex_active_context_tokens(b"{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":-1}}}\n"), None);
        assert_eq!(codex_active_context_tokens(b""), None);
    }

    #[test]
    fn claude_sums_input_and_cache_tokens_and_skips_sidechains() {
        let tail = br#"{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":999}}}
{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":5}}}
{"type":"assistant","message":{"usage":{"output_tokens":7}}}
{"type":"user","message":{"usage":{"input_tokens":1}}}
"#;
        assert_eq!(claude_active_context_tokens(tail), Some(60));
        let boundary = br#"{"type":"assistant","message":{"usage":{"input_tokens":10}}}
{"type":"system","subtype":"compact_boundary","compactMetadata":{"postTokens":4000}}
{"type":"system","subtype":"compact_boundary","compactMetadata":{}}
"#;
        assert_eq!(claude_active_context_tokens(boundary), Some(4000));
    }

    #[test]
    fn lines_end_at_newline_carriage_return_or_both() {
        let objects: Vec<Dict> =
            recent_objects(b"{\"n\":1}\r\n{\"n\":2}\r{\"n\":3}\n\n{\"n\":4}").collect();
        let numbers: Vec<i64> = objects
            .iter()
            .map(|o| o.get("n").unwrap().py_int().unwrap())
            .collect();
        assert_eq!(numbers, [4, 3, 2, 1]);
    }

    #[test]
    fn attempts_advance_per_provider_and_session() {
        let tail =
            br#"{"stage":"compaction_attempt","provider":"codex","session_id":"s","attempt":2}
{"stage":"compaction_unconfirmed","provider":"codex","session_id":"s","attempt":2}
{"stage":"compaction_attempt","provider":"claude","session_id":"s","attempt":9}
{"stage":"active_context_observed","provider":"codex","session_id":"s","attempt":null}
"#;
        assert_eq!(compaction_attempt_number(tail, "codex", "s", true), 3);
        assert_eq!(compaction_attempt_number(tail, "codex", "s", false), 2);
        assert_eq!(compaction_attempt_number(tail, "codex", "other", true), 1);
        assert_eq!(compaction_attempt_number(b"", "codex", "s", false), 1);
        assert_eq!(pending_unconfirmed_attempt(tail, "codex", "s"), Some(2));
        assert_eq!(pending_unconfirmed_attempt(tail, "claude", "s"), None);
        assert_eq!(pending_unconfirmed_attempt(tail, "codex", "other"), None);
    }

    #[test]
    fn tilde_expands_to_the_home_directory_only_at_the_start() {
        let home = std::env::var("HOME").unwrap();
        let home = home.trim_end_matches('/');
        assert_eq!(expand_user("~/a/b"), format!("{home}/a/b"));
        assert_eq!(expand_user("~"), home);
        assert_eq!(expand_user("/a/~/b"), "/a/~/b");
        assert_eq!(expand_user("~other/a"), "~other/a");
    }
}
