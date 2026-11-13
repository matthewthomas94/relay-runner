//! Relay's voice intent model, durable intent inbox and provider-turn broker
//! (RR-489), the Rust form of `services/intent_arbitration.py`,
//! `services/intent_qualification.py`, `services/intent_inbox.py` and
//! `services/provider_turn_broker.py`.
//!
//! The inbox and the broker work in place on the SQLite database the Python
//! bridge writes (`/tmp/relay_intent_inbox.sqlite3`). Until the bridge itself
//! is ported both implementations write it at the same time, so the schema
//! text, the identities and every statement are the Python modules' own. One
//! difference is deliberate: every operation that writes runs in a single
//! `BEGIN IMMEDIATE` transaction, where the Python inbox reads before its
//! write transaction starts. Without contention the results are the same;
//! under contention a Rust read can no longer be overtaken by another writer.
//!
//! `json` and `sha256` are the Python-compatible JSON and the digest every
//! identity is made of; the `relay-rs` hook uses them too.

pub mod arbitration;
pub mod broker;
pub mod database;
pub mod inbox;
pub mod json;
pub mod model;
pub mod pattern;
pub mod qualification;
pub mod sha256;

use std::fmt;

/// A failure, named where the Python module would have raised.
#[derive(Debug)]
pub enum Error {
    /// SQLite refused a statement, or the database could not be opened.
    Sqlite(rusqlite::Error),
    /// A mailbox, state or projection file could not be read or written.
    Io(std::io::Error),
    /// Input the Python module refuses with `ValueError`.
    Invalid(&'static str),
}

pub type Result<T> = std::result::Result<T, Error>;

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Sqlite(error) => write!(formatter, "SQLite: {error}"),
            Error::Io(error) => write!(formatter, "I/O: {error}"),
            Error::Invalid(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for Error {}

impl From<rusqlite::Error> for Error {
    fn from(error: rusqlite::Error) -> Self {
        Error::Sqlite(error)
    }
}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Error::Io(error)
    }
}
