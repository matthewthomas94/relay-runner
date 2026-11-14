//! Program capture and the Graphify projection: `services/program_artifacts.py`
//! ([`artifacts`]), `services/session_capture.py` ([`capture`]) and
//! `services/graphify_ingest.py` ([`ingest`]), on the `graphify.db` store of
//! `relay_store::graphify` and the artifact store of `relay_artifacts`.
//!
//! Project-scoped Program captures are immutable events committed to
//! `refs/heads/relay/artifacts`; Graphify is a disposable projection rebuilt
//! from those events, the registered boards and `runs.db`. Both providers
//! share one event schema.
//!
//! Known differences from the Python modules, each refused or accepted the
//! same way:
//!
//! - A JSON decode failure is reported without Python's position details
//!   (`Expecting value` rather than `Expecting value: line 1 column 1 (char 0)`).
//! - Git output Python decodes strictly (`text=True`) is decoded lossily, so
//!   non-UTF-8 output is read rather than raising `UnicodeDecodeError`; the
//!   same holds for the first lines of a run log read to infer its provider.
//! - A file whose path is not UTF-8 is left out of the file index, where
//!   Python would fail the ingest when SQLite refuses the surrogate.

pub mod artifacts;
pub mod capture;
pub mod ingest;

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use relay_intents::json::{self, Dict, Value};
use relay_store::graphify::{Graph, GraphifyStore};

use crate::{Error, Result};

/// `_optional_text(value)`: `str(value).strip()`, or `None` when the value is
/// `None` or the text is blank.
pub(crate) fn optional_text(value: Option<&Value>) -> Option<String> {
    match value {
        None | Some(Value::Null) => None,
        Some(value) => {
            let text = json::py_strip(&value.py_str()).to_string();
            (!text.is_empty()).then_some(text)
        }
    }
}

/// `repr(value)` for a JSON value.
pub(crate) fn repr(value: &Value) -> String {
    match value {
        Value::Str(text) => json::str_repr(text),
        other => other.py_str(),
    }
}

/// `str(value or "")`.
pub(crate) fn str_or_empty(value: Option<&Value>) -> String {
    match value {
        Some(value) if value.truthy() => value.py_str(),
        _ => String::new(),
    }
}

/// `d.get(key)`, `None` when absent.
pub(crate) fn get(dict: &Dict, key: &str) -> Value {
    dict.get(key).cloned().unwrap_or(Value::Null)
}

/// `d.get(key) if isinstance(d.get(key), dict) else {}`.
pub(crate) fn dict_or_empty(dict: &Dict, key: &str) -> Dict {
    dict.get(key)
        .and_then(Value::as_dict)
        .cloned()
        .unwrap_or_default()
}

/// `str(Path(text).expanduser().resolve())`.
pub(crate) fn resolve_path(text: &str) -> Result<String> {
    let expanded = relay_artifacts::paths::expanduser(text)?;
    Ok(relay_artifacts::paths::resolve(&expanded))
}

/// A value with every object's keys sorted, as `sort_keys=True` writes it.
pub(crate) fn sorted_keys(value: &Value) -> Value {
    match value {
        Value::Dict(dict) => {
            let mut entries: Vec<(&str, &Value)> = dict.iter().collect();
            entries.sort_by(|left, right| left.0.cmp(right.0));
            let mut sorted = Dict::new();
            for (key, item) in entries {
                sorted.insert(key, sorted_keys(item));
            }
            Value::Dict(sorted)
        }
        Value::List(items) => Value::List(items.iter().map(sorted_keys).collect()),
        other => other.clone(),
    }
}

/// `int(value)` with Python's error: `ValueError` for text that is not an
/// integer, `TypeError` for anything that is not a string or a number.
pub(crate) fn py_int(value: &Value) -> Result<i64> {
    match value {
        Value::Str(text) => value.py_int().ok_or_else(|| {
            Error::value(format!(
                "invalid literal for int() with base 10: {}",
                json::str_repr(text)
            ))
        }),
        Value::Bool(_) | Value::Int(_) | Value::Float(_) => value
            .py_int()
            .ok_or_else(|| Error::value("cannot convert float NaN to integer")),
        Value::BigInt(_) => Err(Error::new("OverflowError", "integer out of range")),
        other => Err(Error::new(
            "TypeError",
            format!(
                "int() argument must be a string, a bytes-like object or a real number, not '{}'",
                relay_artifacts::pystr::type_name(other)
            ),
        )),
    }
}

/// `float(value)` with Python's error.
pub(crate) fn py_float(value: &Value) -> Result<f64> {
    match value {
        Value::Str(text) => value.py_float().ok_or_else(|| {
            Error::value(format!(
                "could not convert string to float: {}",
                json::str_repr(text)
            ))
        }),
        Value::Bool(_) | Value::Int(_) | Value::Float(_) | Value::BigInt(_) => {
            Ok(value.py_float().unwrap_or(f64::NAN))
        }
        other => Err(Error::new(
            "TypeError",
            format!(
                "float() argument must be a string or a real number, not '{}'",
                relay_artifacts::pystr::type_name(other)
            ),
        )),
    }
}

/// A finished `git -C <repo> …`, run with the daemon's own environment as
/// `subprocess.run(["git", "-C", repo, …])` runs it.
pub(crate) struct GitOutput {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl GitOutput {
    pub fn ok(&self) -> bool {
        self.status == 0
    }

    /// The output as text mode reads it: decoded, with universal newlines.
    pub fn text(&self) -> String {
        relay_artifacts::pystr::universal_newlines(&String::from_utf8_lossy(&self.stdout))
    }

    pub fn stderr_text(&self) -> String {
        relay_artifacts::pystr::universal_newlines(&String::from_utf8_lossy(&self.stderr))
    }
}

/// Runs git; a process that cannot start reports status -1, as a failed
/// `subprocess.run` would be treated by every caller here.
pub(crate) fn git(repo: &Path, arguments: &[&str], input: Option<&[u8]>) -> GitOutput {
    let child = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(arguments)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let Ok(mut child) = child else {
        return GitOutput {
            status: -1,
            stdout: Vec::new(),
            stderr: b"git could not start".to_vec(),
        };
    };
    let output = std::thread::scope(|scope| {
        if let (Some(bytes), Some(mut stdin)) = (input, child.stdin.take()) {
            scope.spawn(move || {
                let _ = stdin.write_all(bytes);
            });
        }
        child.wait_with_output()
    });
    match output {
        Ok(output) => GitOutput {
            status: output.status.code().unwrap_or(-1),
            stdout: output.stdout,
            stderr: output.stderr,
        },
        Err(error) => GitOutput {
            status: -1,
            stdout: Vec::new(),
            stderr: error.to_string().into_bytes(),
        },
    }
}

/// `uuid.uuid4().hex`: 32 random lowercase hex digits.
pub(crate) fn random_hex() -> String {
    let mut bytes = [0u8; 16];
    if let Ok(mut file) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        let _ = file.read_exact(&mut bytes);
    }
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `str.title()`: each run of letters capitalised.
pub(crate) fn title_case(text: &str) -> String {
    let mut result = String::new();
    let mut start = true;
    for character in text.chars() {
        if character.is_alphabetic() {
            if start {
                result.extend(character.to_uppercase());
            } else {
                result.extend(character.to_lowercase());
            }
            start = false;
        } else {
            result.push(character);
            start = true;
        }
    }
    result
}

/// Runs service `work` on the store with each statement committed as it runs
/// (`GraphifyStore::with`), returning the service's own error.
pub fn with_graph<T>(
    store: &GraphifyStore,
    work: impl FnOnce(&Graph<'_>) -> Result<T>,
) -> Result<T> {
    let mut failure = None;
    let result = store.with(|graph| {
        work(graph).map_err(|error| {
            failure = Some(error);
            relay_store::Error::Invalid(String::new())
        })
    });
    result.map_err(|error| failure.take().unwrap_or_else(|| error.into()))
}

/// Runs service `work` as one `graphify.db` transaction
/// (`GraphifyStore::transaction`); an error rolls it back and is returned as
/// the service raised it.
pub fn in_transaction<T>(
    store: &GraphifyStore,
    work: impl FnOnce(&Graph<'_>) -> Result<T>,
) -> Result<T> {
    let mut failure = None;
    let result = store.transaction(|graph| {
        work(graph).map_err(|error| {
            failure = Some(error);
            relay_store::Error::Invalid(String::new())
        })
    });
    result.map_err(|error| failure.take().unwrap_or_else(|| error.into()))
}
