//! What the completion hook and the reply helper share: the environment, the
//! claim and state files, command identity and the bridge's FIFO.

use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::json::{self, Dict, Value, py_strip};

pub const FOREGROUND_OWNERSHIP_FIELDS: [&str; 4] = [
    "app_session_id",
    "recovery_generation",
    "actor_role",
    "foreground_gate_handle",
];
const FOREGROUND_ACTOR_ROLES: [&str; 2] = ["foreground_pm", "foreground_manual"];

/// A failure the Python scripts would have raised, named by its exception
/// class. Diagnostics print only this name, never the data that caused it.
#[derive(Debug)]
pub struct Failure(pub &'static str);

impl From<io::Error> for Failure {
    fn from(error: io::Error) -> Self {
        Failure(match error.kind() {
            io::ErrorKind::NotFound => "FileNotFoundError",
            io::ErrorKind::PermissionDenied => "PermissionError",
            io::ErrorKind::WouldBlock => "BlockingIOError",
            io::ErrorKind::BrokenPipe => "BrokenPipeError",
            _ => "OSError",
        })
    }
}

static STARTED: OnceLock<Instant> = OnceLock::new();

/// Both providers stop a hook after 2 seconds. Waiting for a locked inbox or
/// a full FIFO ends this long after the process started, so the hook always
/// exits by itself.
const WAIT_BUDGET: Duration = Duration::from_millis(1500);

/// Starts the clock `wait_deadline` measures from; call once, first.
pub fn start_clock() {
    STARTED.get_or_init(Instant::now);
}

pub fn wait_deadline() -> Instant {
    *STARTED.get_or_init(Instant::now) + WAIT_BUDGET
}

/// `time.time()`.
pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

/// `time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(seconds))`.
pub fn utc_timestamp(seconds: f64) -> String {
    let total = seconds.floor() as i64;
    let (days, second_of_day) = (total.div_euclid(86_400), total.rem_euclid(86_400));
    // Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        second_of_day / 3600,
        second_of_day % 3600 / 60,
        second_of_day % 60
    )
}

/// `os.environ.get(name, default)`.
pub fn env_or(name: &str, default: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| default.to_string())
}

/// `os.environ.get(name)`.
pub fn env_optional(name: &str) -> Option<String> {
    std::env::var(name).ok()
}

/// `os.environ.get(name, "").strip()`.
pub fn env_text(name: &str) -> String {
    py_strip(&env_or(name, "")).to_string()
}

/// The four ownership fields as the app exported them, trimmed.
pub fn ownership_from_environment() -> Dict {
    let mut ownership = Dict::new();
    for (field, variable) in FOREGROUND_OWNERSHIP_FIELDS.iter().zip([
        "RELAY_APP_SESSION_ID",
        "RELAY_RECOVERY_GENERATION",
        "RELAY_ACTOR_ROLE",
        "RELAY_FOREGROUND_GATE_HANDLE",
    ]) {
        ownership.insert(field, env_text(variable));
    }
    ownership
}

/// Whether `ownership` names a foreground actor and is complete.
pub fn is_foreground_owner(ownership: &Dict) -> bool {
    FOREGROUND_ACTOR_ROLES.contains(&ownership.string("actor_role").as_str())
        && FOREGROUND_OWNERSHIP_FIELDS
            .iter()
            .all(|field| ownership.truthy(field).is_some())
}

/// Everything on stdin.
pub fn read_stdin() -> Vec<u8> {
    let mut data = Vec::new();
    // An unreadable stdin is an empty one, which every mode refuses.
    let _ = io::stdin().lock().read_to_end(&mut data);
    data
}

/// The object in a JSON file; anything unreadable is an empty object.
pub fn read_json_file(path: &str) -> Dict {
    match fs::read(path)
        .ok()
        .and_then(|bytes| json::parse_bytes(&bytes))
    {
        Some(Value::Dict(dict)) => dict,
        _ => Dict::new(),
    }
}

/// Replaces `path` with `payload` as key-sorted JSON, through `<path>.tmp`.
pub fn atomic_write_json(path: &str, payload: &Value) -> Result<(), Failure> {
    let temporary = format!("{path}.tmp");
    fs::write(&temporary, json::dumps_sorted(payload))?;
    fs::rename(&temporary, path)?;
    Ok(())
}

/// The command a claim, state or ledger record names: an integer sequence and
/// a non-empty id.
pub fn relay_command_key(command: &Dict) -> Option<(i64, String)> {
    let command_id = command.text("relay_command_id");
    if command_id.is_empty() {
        return None;
    }
    let command_seq = command.get("relay_command_seq")?.py_int()?;
    Some((command_seq, command_id))
}

/// Whether `state` lists the command's intent as cancelled.
pub fn intent_cancelled(state: &Dict, command: &Dict) -> bool {
    let intent_id = command.string("intent_id");
    state
        .get("cancelled_intent_ids")
        .and_then(Value::as_list)
        .is_some_and(|cancelled| cancelled.iter().any(|value| value.py_str() == intent_id))
}

/// Whether the newest command lets the current work finish.
pub fn preserves_current_work(state: &Dict) -> bool {
    let Some(disposition) = state.get("work_disposition").and_then(Value::as_dict) else {
        return false;
    };
    let field_is = |field: &str, text: &str| disposition.get(field).is_some_and(|v| v.is_str(text));
    field_is("route", "continue_current")
        && field_is("authorization_effect", "preserve")
        && match disposition.get("cancellation_scope") {
            None | Some(Value::Null) => true,
            Some(scope) => scope.is_str("none"),
        }
}

/// Whether `command` is the newest command in `state`, or one the newest
/// command preserves.
pub fn current_or_preserved(command_key: &(i64, String), state: &Dict) -> bool {
    match relay_command_key(state) {
        Some(state_key) if state_key == *command_key => true,
        Some(state_key) if state_key.0 > command_key.0 => preserves_current_work(state),
        _ => false,
    }
}

/// Writes `line` and a newline to the bridge's FIFO. `Ok(false)` means there
/// is no FIFO or nothing is reading it, which is not an error.
///
/// The FIFO is opened without blocking so a missing reader is seen at once.
/// A line longer than the FIFO buffer is then written as the reader drains
/// it, until `deadline`.
pub fn write_fifo_line(path: &str, line: &str, deadline: Instant) -> Result<bool, Failure> {
    let opened = OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path);
    let mut fifo = match opened {
        Ok(fifo) => fifo,
        Err(error)
            if error.kind() == io::ErrorKind::NotFound
                || error.raw_os_error() == Some(libc::ENXIO) =>
        {
            return Ok(false);
        }
        Err(error) => return Err(error.into()),
    };
    let mut data = Vec::with_capacity(line.len() + 1);
    data.extend_from_slice(line.as_bytes());
    data.push(b'\n');
    let mut written = 0;
    while written < data.len() {
        match fifo.write(&data[written..]) {
            Ok(0) => return Err(Failure("OSError")),
            Ok(count) => written += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if Instant::now() >= deadline {
                    return Err(Failure("BlockingIOError"));
                }
                thread::sleep(Duration::from_millis(1));
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dict(text: &str) -> Dict {
        match json::parse(text) {
            Some(Value::Dict(dict)) => dict,
            _ => panic!("not an object: {text}"),
        }
    }

    #[test]
    fn utc_timestamp_matches_gmtime() {
        assert_eq!(utc_timestamp(0.0), "1970-01-01T00:00:00Z");
        assert_eq!(utc_timestamp(951_782_399.9), "2000-02-28T23:59:59Z");
        assert_eq!(utc_timestamp(951_782_400.0), "2000-02-29T00:00:00Z");
        assert_eq!(utc_timestamp(1_731_300_000.5), "2024-11-11T04:40:00Z");
        assert_eq!(utc_timestamp(4_102_444_799.0), "2099-12-31T23:59:59Z");
    }

    #[test]
    fn command_key_needs_an_id_and_an_integer_sequence() {
        let key = |text: &str| relay_command_key(&dict(text));
        assert_eq!(
            key(r#"{"relay_command_id": " cmd-7 ", "relay_command_seq": "7"}"#),
            Some((7, "cmd-7".into()))
        );
        assert_eq!(
            key(r#"{"relay_command_id": "cmd-7", "relay_command_seq": 7.0}"#),
            Some((7, "cmd-7".into()))
        );
        assert_eq!(
            key(r#"{"relay_command_id": "", "relay_command_seq": 7}"#),
            None
        );
        assert_eq!(
            key(r#"{"relay_command_id": "cmd-7", "relay_command_seq": "next"}"#),
            None
        );
        assert_eq!(
            key(r#"{"relay_command_id": "cmd-7", "relay_command_seq": null}"#),
            None
        );
        assert_eq!(key(r#"{"relay_command_id": "cmd-7"}"#), None);
    }

    #[test]
    fn newer_command_preserves_only_with_the_exact_disposition() {
        let command = (7, "cmd-7".to_string());
        let state = |disposition: &str| {
            dict(&format!(
                r#"{{"relay_command_id": "cmd-8", "relay_command_seq": 8, "work_disposition": {disposition}}}"#
            ))
        };
        let preserve = r#"{"route": "continue_current", "authorization_effect": "preserve""#;
        assert!(current_or_preserved(
            &command,
            &state(&format!("{preserve}}}"))
        ));
        assert!(current_or_preserved(
            &command,
            &state(&format!(r#"{preserve}, "cancellation_scope": "none"}}"#))
        ));
        assert!(current_or_preserved(
            &command,
            &state(&format!(r#"{preserve}, "cancellation_scope": null}}"#))
        ));
        assert!(!current_or_preserved(
            &command,
            &state(&format!(
                r#"{preserve}, "cancellation_scope": "current_item"}}"#
            ))
        ));
        assert!(!current_or_preserved(&command, &state("null")));
        assert!(!current_or_preserved(
            &command,
            &state(r#""continue_current""#)
        ));
        assert!(current_or_preserved(
            &command,
            &dict(r#"{"relay_command_id": "cmd-7", "relay_command_seq": 7}"#)
        ));
        assert!(!current_or_preserved(
            &command,
            &dict(r#"{"relay_command_id": "cmd-x", "relay_command_seq": 7}"#)
        ));
        assert!(!current_or_preserved(
            &command,
            &dict(r#"{"relay_command_id": "cmd-6", "relay_command_seq": 6}"#)
        ));
        assert!(!current_or_preserved(&command, &Dict::new()));
    }

    #[test]
    fn cancelled_intents_are_compared_as_text() {
        let state = dict(r#"{"cancelled_intent_ids": ["intent-3", 7]}"#);
        assert!(intent_cancelled(
            &state,
            &dict(r#"{"intent_id": "intent-3"}"#)
        ));
        assert!(intent_cancelled(&state, &dict(r#"{"intent_id": 7}"#)));
        assert!(!intent_cancelled(
            &state,
            &dict(r#"{"intent_id": "intent-7"}"#)
        ));
        assert!(!intent_cancelled(
            &dict(r#"{"cancelled_intent_ids": "intent-3"}"#),
            &dict(r#"{"intent_id": "intent-3"}"#)
        ));
    }
}
