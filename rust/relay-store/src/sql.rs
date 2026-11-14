//! What every store shares: opening a database the way Python's `sqlite3`
//! does, the store lock, moving values between SQLite and JSON, and the few
//! Python spellings (`Path.resolve()`, `str.splitlines()`, `json.dumps(...,
//! indent=2)`) their rows depend on.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, Row};

use relay_intents::json::{self, Dict, Value};

use crate::{Error, Result};

/// Python's `sqlite3.connect` default lock wait.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(5);

/// Opens `path` with Python's defaults: a 5 second (or `timeout`) busy wait
/// and no foreign-key enforcement. The bundled SQLite enforces foreign keys
/// by default and Python's does not; Graphify turns them on itself.
pub fn connect(path: &Path, timeout: Duration) -> Result<Connection> {
    let connection = Connection::open(path)?;
    connection.busy_timeout(timeout)?;
    connection.pragma_update(None, "foreign_keys", false)?;
    Ok(connection)
}

/// `path.parent.mkdir(parents=True, exist_ok=True)`.
pub(crate) fn make_parent(path: &Path) -> Result<()> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent)?;
    }
    Ok(())
}

/// One long-lived connection behind the store's lock, as
/// `_store_connection` keeps it. A call that returns with a transaction still
/// open is rolled back, which is what closing a per-call connection did.
pub(crate) struct Db {
    pub(crate) path: PathBuf,
    connection: Mutex<Connection>,
}

impl Db {
    pub(crate) fn open(path: &Path, timeout: Duration) -> Result<Self> {
        make_parent(path)?;
        Ok(Self {
            path: path.to_path_buf(),
            connection: Mutex::new(connect(path, timeout)?),
        })
    }

    pub(crate) fn lock(&self) -> MutexGuard<'_, Connection> {
        self.connection
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub(crate) fn with<T>(&self, work: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let connection = self.lock();
        let result = work(&connection);
        if !connection.is_autocommit() {
            let _ = connection.execute_batch("ROLLBACK");
        }
        result
    }
}

/// Runs `work` inside `BEGIN` (or `BEGIN IMMEDIATE`); an error rolls back.
pub(crate) fn transaction<T>(
    connection: &Connection,
    begin: &str,
    work: impl FnOnce() -> Result<T>,
) -> Result<T> {
    connection.execute_batch(begin)?;
    match work() {
        Ok(value) => {
            connection.execute_batch("COMMIT")?;
            Ok(value)
        }
        Err(error) => {
            let _ = connection.execute_batch("ROLLBACK");
            Err(error)
        }
    }
}

pub fn user_version(connection: &Connection) -> Result<i64> {
    Ok(connection.query_row("PRAGMA user_version", [], |row| row.get(0))?)
}

pub(crate) fn set_user_version(connection: &Connection, version: i64) -> Result<()> {
    connection.execute_batch(&format!("PRAGMA user_version = {version}"))?;
    Ok(())
}

/// The names of `table`'s columns, in order.
pub fn table_columns(connection: &Connection, table: &str) -> Result<Vec<String>> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let names = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(names)
}

/// A SQLite value as Python's `sqlite3` returns it.
pub fn sql_to_json(value: Sql) -> Value {
    relay_intents::database::sql_to_json(value)
}

/// `dict(row)`: every column of `row` under its own name.
pub(crate) fn row_dict(row: &Row<'_>) -> rusqlite::Result<Dict> {
    let mut record = Dict::new();
    let statement = row.as_ref();
    for index in 0..statement.column_count() {
        let name = statement.column_name(index)?;
        record.insert(name, sql_to_json(row.get(index)?));
    }
    Ok(record)
}

/// Every row of `sql` as `dict(row)`.
pub(crate) fn rows(connection: &Connection, sql: &str, params: &[Sql]) -> Result<Vec<Dict>> {
    let mut statement = connection.prepare(sql)?;
    let rows = statement
        .query_map(rusqlite::params_from_iter(params.iter()), row_dict)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

/// The first row of `sql` as `dict(row)`, or `None`.
pub(crate) fn row(connection: &Connection, sql: &str, params: &[Sql]) -> Result<Option<Dict>> {
    let mut statement = connection.prepare(sql)?;
    let mut found = statement.query(rusqlite::params_from_iter(params.iter()))?;
    match found.next()? {
        Some(row) => Ok(Some(row_dict(row)?)),
        None => Ok(None),
    }
}

/// Runs one statement and returns its change count.
pub(crate) fn execute(connection: &Connection, sql: &str, params: &[Sql]) -> Result<usize> {
    let mut statement = connection.prepare(sql)?;
    Ok(statement.execute(rusqlite::params_from_iter(params.iter()))?)
}

/// Bind helpers: Python's `None` for a missing value.
pub(crate) fn text(value: impl Into<String>) -> Sql {
    Sql::Text(value.into())
}

pub(crate) fn opt_text<S: AsRef<str>>(value: Option<S>) -> Sql {
    value.map_or(Sql::Null, |value| Sql::Text(value.as_ref().to_string()))
}

pub(crate) fn int(value: i64) -> Sql {
    Sql::Integer(value)
}

pub(crate) fn opt_int(value: Option<i64>) -> Sql {
    value.map_or(Sql::Null, Sql::Integer)
}

pub(crate) fn real(value: f64) -> Sql {
    Sql::Real(value)
}

pub(crate) fn opt_real(value: Option<f64>) -> Sql {
    value.map_or(Sql::Null, Sql::Real)
}

/// Python's `==` between two bound values: numbers compare by value.
pub(crate) fn sql_eq(left: &Sql, right: &Sql) -> bool {
    match (left, right) {
        (Sql::Integer(a), Sql::Real(b)) | (Sql::Real(b), Sql::Integer(a)) => (*a as f64) == *b,
        _ => left == right,
    }
}

/// `time.time()`.
pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

/// `?` placeholders for an `IN (…)` list of `count` values.
pub(crate) fn placeholders(count: usize) -> String {
    vec!["?"; count].join(",")
}

/// `row[key]` as text, or `""` where it is not text.
pub(crate) fn field_str<'a>(row: &'a Dict, key: &str) -> &'a str {
    row.get(key).and_then(Value::as_str).unwrap_or("")
}

/// `row[key]` as an integer, where it is one.
pub(crate) fn field_int(row: &Dict, key: &str) -> Option<i64> {
    match row.get(key) {
        Some(Value::Int(number)) => Some(*number),
        _ => None,
    }
}

/// `Path(path).expanduser()`.
pub fn expand_user(path: &str) -> String {
    if path == "~" || path.starts_with("~/") {
        let home = std::env::var("HOME").unwrap_or_default();
        format!("{home}{}", &path[1..])
    } else {
        path.to_string()
    }
}

/// `Path(path).expanduser().resolve()`: absolute, symlinks resolved where the
/// path exists, the rest normalised lexically (`os.path.realpath`).
pub fn resolve_path(path: &str) -> String {
    resolve(&expand_user(path))
}

/// `Path(path).resolve()`, without `~` expansion.
pub fn resolve(path: &str) -> String {
    let absolute = if path.starts_with('/') {
        path.to_string()
    } else {
        let cwd = std::env::current_dir()
            .map(|cwd| cwd.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "/".to_string());
        format!("{cwd}/{path}")
    };
    let mut resolved = String::new();
    let mut links = 0;
    join_resolved(&mut resolved, &absolute, &mut links);
    if resolved.is_empty() {
        "/".to_string()
    } else {
        resolved
    }
}

/// `posixpath._joinrealpath`: appends `rest` to the already-resolved
/// `resolved` ("" is the root), following symlinks that exist.
fn join_resolved(resolved: &mut String, rest: &str, links: &mut usize) {
    if rest.starts_with('/') {
        resolved.clear();
    }
    for name in rest.split('/') {
        if name.is_empty() || name == "." {
            continue;
        }
        if name == ".." {
            match resolved.rfind('/') {
                Some(position) => resolved.truncate(position),
                None => resolved.clear(),
            }
            continue;
        }
        let candidate = format!("{resolved}/{name}");
        let is_link = fs::symlink_metadata(&candidate)
            .map(|metadata| metadata.file_type().is_symlink())
            .unwrap_or(false);
        if !is_link || *links >= 40 {
            *resolved = candidate;
            continue;
        }
        *links += 1;
        match fs::read_link(&candidate) {
            Ok(target) => join_resolved(resolved, &target.to_string_lossy(), links),
            Err(_) => *resolved = candidate,
        }
    }
}

/// `str.splitlines()`.
pub(crate) fn py_splitlines(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut characters = text.char_indices().peekable();
    while let Some((index, character)) = characters.next() {
        let breaks = matches!(
            character,
            '\n' | '\r'
                | '\u{0b}'
                | '\u{0c}'
                | '\u{1c}'
                | '\u{1d}'
                | '\u{1e}'
                | '\u{85}'
                | '\u{2028}'
                | '\u{2029}'
        );
        if !breaks {
            continue;
        }
        lines.push(&text[start..index]);
        let mut end = index + character.len_utf8();
        if character == '\r'
            && let Some(&(next, '\n')) = characters.peek()
        {
            characters.next();
            end = next + 1;
        }
        start = end;
    }
    if start < text.len() {
        lines.push(&text[start..]);
    }
    lines
}

/// `re.sub(r"\s+", " ", text).strip()`.
pub(crate) fn collapse_whitespace(text: &str) -> String {
    let mut collapsed = String::with_capacity(text.len());
    let mut pending_space = false;
    for character in text.chars() {
        if json::py_is_space(character) {
            pending_space = !collapsed.is_empty();
        } else {
            if pending_space {
                collapsed.push(' ');
                pending_space = false;
            }
            collapsed.push(character);
        }
    }
    collapsed
}

/// `_clean_optional_multiline_text`: each line's whitespace collapsed, blank
/// lines dropped, `None` when nothing is left.
pub(crate) fn clean_optional_multiline_text(value: Option<&str>) -> Option<String> {
    let value = value?;
    let lines: Vec<String> = py_splitlines(value)
        .into_iter()
        .map(collapse_whitespace)
        .filter(|line| !line.is_empty())
        .collect();
    let text = json::py_strip(&lines.join("\n")).to_string();
    (!text.is_empty()).then_some(text)
}

/// Python's `repr()` of a string, for error messages.
pub(crate) fn py_repr(text: &str) -> String {
    let quote = if text.contains('\'') && !text.contains('"') {
        '"'
    } else {
        '\''
    };
    let mut repr = String::with_capacity(text.len() + 2);
    repr.push(quote);
    for character in text.chars() {
        match character {
            '\\' => repr.push_str("\\\\"),
            '\n' => repr.push_str("\\n"),
            '\r' => repr.push_str("\\r"),
            '\t' => repr.push_str("\\t"),
            character if character == quote => {
                repr.push('\\');
                repr.push(character);
            }
            character if (character as u32) < 0x20 || character as u32 == 0x7f => {
                repr.push_str(&format!("\\x{:02x}", character as u32));
            }
            character => repr.push(character),
        }
    }
    repr.push(quote);
    repr
}

/// `json.dumps(value, indent=2)`: insertion order, ASCII escapes, `repr`
/// floats, `","` between items and `": "` after keys.
pub fn dumps_indent(value: &Value) -> String {
    let mut out = String::new();
    write_indented(&mut out, value, 0);
    out
}

fn write_indented(out: &mut String, value: &Value, depth: usize) {
    match value {
        Value::List(items) if !items.is_empty() => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                newline(out, depth + 1);
                write_indented(out, item, depth + 1);
            }
            newline(out, depth);
            out.push(']');
        }
        Value::Dict(object) if !object.is_empty() => {
            out.push('{');
            for (index, (key, item)) in object.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                newline(out, depth + 1);
                out.push_str(&json::dumps(&Value::Str(key.to_string())));
                out.push_str(": ");
                write_indented(out, item, depth + 1);
            }
            newline(out, depth);
            out.push('}');
        }
        other => out.push_str(&json::dumps(other)),
    }
}

fn newline(out: &mut String, depth: usize) {
    out.push('\n');
    for _ in 0..depth {
        out.push_str("  ");
    }
}

/// `json.loads(text)`, refusing what Python refuses.
pub(crate) fn loads(text: &str, what: &str) -> Result<Value> {
    json::parse(text).ok_or_else(|| Error::invalid(format!("{what} is not valid JSON")))
}

/// A list of strings as a JSON value.
pub(crate) fn string_list(items: &[String]) -> Value {
    Value::List(items.iter().map(|item| Value::Str(item.clone())).collect())
}

/// Eight random bytes, as hex (`uuid.uuid4().hex[:16]`).
pub(crate) fn random_hex16() -> Result<String> {
    use std::io::Read;
    let mut bytes = [0u8; 8];
    fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splitlines_and_cleaning_follow_python() {
        assert_eq!(
            py_splitlines("a\r\nb\rc\n\nd\n"),
            vec!["a", "b", "c", "", "d"]
        );
        assert_eq!(py_splitlines(""), Vec::<&str>::new());
        assert_eq!(
            clean_optional_multiline_text(Some("  one   two \n\n\t three\u{2028}")),
            Some("one two\nthree".to_string())
        );
        assert_eq!(clean_optional_multiline_text(Some(" \n ")), None);
        assert_eq!(clean_optional_multiline_text(None), None);
    }

    #[test]
    fn repr_and_indent_follow_python() {
        assert_eq!(py_repr("abc"), "'abc'");
        assert_eq!(py_repr("it's"), "\"it's\"");
        let mut object = Dict::new();
        object.insert("runs", Value::List(vec![]));
        object.insert("x", Value::Float(1.0));
        let mut inner = Dict::new();
        inner.insert("é", Value::Null);
        object.insert(
            "o",
            Value::List(vec![Value::Dict(inner), Value::Dict(Dict::new())]),
        );
        assert_eq!(
            dumps_indent(&Value::Dict(object)),
            "{\n  \"runs\": [],\n  \"x\": 1.0,\n  \"o\": [\n    {\n      \"\\u00e9\": null\n    },\n    {}\n  ]\n}"
        );
    }

    #[test]
    fn resolve_follows_symlinks_and_dots() {
        assert_eq!(resolve("/a/b/../c/./d"), "/a/c/d");
        assert_eq!(resolve("/"), "/");
        // /tmp is a symlink to /private/tmp on macOS.
        let tmp = fs::canonicalize("/tmp").unwrap();
        assert_eq!(
            resolve("/tmp/relay-store-missing/x"),
            format!("{}/relay-store-missing/x", tmp.display())
        );
    }
}
