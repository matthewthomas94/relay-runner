//! The orchestrator daemon's SQLite stores (RR-496), the Rust form of the
//! store classes in `services/orchestrator.py` (`RunsStore`,
//! `QueueDrainStore`, `OrchestratorSessionStore`, `OrchestratorCommandStore`,
//! `MessengerOutcomeStore`), `services/followup_tickets.py`,
//! `services/continuity_reports.py`, `services/graphify_core.py`, the task
//! ledger of `services/general_work.py` and the catalog of
//! `services/personal_file_storage.py` and `services/personal_notes.py`.
//!
//! A Rust and a Python daemon must be able to take turns on one data root with
//! no migration, so every database is opened in place: the schema text, the
//! `PRAGMA user_version` gates, the migrations from earlier versions, the
//! statements and the JSON written into rows are the Python modules' own. A
//! row comes back as a [`Dict`] with the keys, order and values the Python
//! store returns, ready for the HTTP layer to serialise.
//!
//! One difference is deliberate. Where a Python store meets a
//! `user_version` newer than it knows, it drops the tables and starts again;
//! these stores refuse to open instead ([`Error::NewerSchema`]), so a Rust
//! daemon never destroys rows a later Python release wrote.
//!
//! Domain rules the stores do not own stay with their callers: drafts arrive
//! sanitised, continuity reports arrive built, and worker execution, the
//! personal-storage sync and the program ingest are later parts of the port.

pub mod commands;
pub mod continuity;
pub mod daemon;
pub mod followups;
pub mod general_work;
pub mod graphify;
pub mod messenger;
pub mod personal_catalog;
pub mod queue_drains;
pub mod runs;
pub mod sessions;
pub mod sha1;
pub mod sql;

use std::fmt;

pub use relay_intents::json::{Dict, Value};

/// A failure, named where the Python store would have raised.
#[derive(Debug)]
pub enum Error {
    /// SQLite refused a statement, or the database could not be opened.
    Sqlite(rusqlite::Error),
    /// A directory or file beside a database could not be made or written.
    Io(std::io::Error),
    /// Input the Python store refuses with `ValueError`, with its message.
    Invalid(String),
    /// A database whose `user_version` is newer than this build knows.
    NewerSchema {
        database: &'static str,
        found: i64,
        supported: i64,
    },
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        Error::Invalid(message.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Sqlite(error) => write!(formatter, "SQLite: {error}"),
            Error::Io(error) => write!(formatter, "I/O: {error}"),
            Error::Invalid(message) => formatter.write_str(message),
            Error::NewerSchema {
                database,
                found,
                supported,
            } => write!(
                formatter,
                "unsupported {database} schema version {found}; expected <= {supported}"
            ),
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
