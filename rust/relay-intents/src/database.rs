//! Opening the shared database, moving values between SQLite and JSON, and
//! the write transaction every mutating operation runs in.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, Row};

use crate::json::{Dict, Value};
use crate::{Error, Result};

/// How a connection waits for another writer's lock.
#[derive(Clone, Copy, Debug)]
pub enum LockWait {
    /// SQLite's busy timeout. Python's `sqlite3.connect` waits 5 seconds and
    /// the broker sets `busy_timeout=5000`.
    Timeout(Duration),
    /// A busy handler: called with the retry count, `false` gives up. The
    /// `relay-rs` hook stops waiting at its own deadline.
    Handler(fn(i32) -> bool),
}

impl Default for LockWait {
    fn default() -> Self {
        LockWait::Timeout(Duration::from_millis(5000))
    }
}

/// Opens `path` the way both implementations share it.
pub(crate) fn connect(path: &str, lock_wait: LockWait) -> Result<Connection> {
    let mut connection = Connection::open(path)?;
    match lock_wait {
        LockWait::Timeout(timeout) => connection.busy_timeout(timeout)?,
        LockWait::Handler(handler) => connection.busy_handler(Some(handler))?,
    }
    // The bundled SQLite enforces foreign keys by default; Python's does not,
    // and the broker's rows may name turns another writer has not committed.
    connection.pragma_update(None, "foreign_keys", false)?;
    connection.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))?;
    Ok(connection)
}

/// Runs `work` inside `BEGIN IMMEDIATE`; an error rolls back.
pub(crate) fn immediate<T>(connection: &Connection, work: impl FnOnce() -> Result<T>) -> Result<T> {
    connection.execute_batch("BEGIN IMMEDIATE")?;
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

/// A SQLite value as Python's `sqlite3` returns it.
pub fn sql_to_json(value: Sql) -> Value {
    match value {
        Sql::Integer(number) => Value::Int(number),
        Sql::Real(number) => Value::Float(number),
        Sql::Text(text) => Value::Str(text),
        Sql::Null | Sql::Blob(_) => Value::Null,
    }
}

/// A JSON value as Python's `sqlite3` binds it. A list or an object cannot be
/// bound, and Python raises there too.
pub(crate) fn bind(value: Option<&Value>) -> Result<Sql> {
    Ok(match value {
        None | Some(Value::Null) => Sql::Null,
        Some(Value::Bool(flag)) => Sql::Integer(i64::from(*flag)),
        Some(Value::Int(number)) => Sql::Integer(*number),
        Some(Value::Float(number)) => Sql::Real(*number),
        Some(Value::Str(text)) => Sql::Text(text.clone()),
        Some(Value::BigInt(_) | Value::List(_) | Value::Dict(_)) => {
            return Err(Error::Invalid("unsupported parameter type"));
        }
    })
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

/// `time.time()`.
pub(crate) fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

/// `time.time_ns()`.
pub(crate) fn now_ns() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos())
}

/// `?` placeholders for an `IN (…)` list of `count` values.
pub(crate) fn placeholders(count: usize) -> String {
    vec!["?"; count].join(",")
}
