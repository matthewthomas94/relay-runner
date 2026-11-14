//! The orchestrator daemon's services (RR-499), the Rust form of the Python
//! modules in `services/` that sit beside the HTTP routes: the notes library
//! and personal storage, program capture, status and graph ingest, the
//! continuity lane, General work, Relay command authorization and command
//! actions, and the provider gates (Claude subscription readiness and the
//! Codex model catalogue). Command actions, authorization and the provider
//! gates were first ported for the voice bridge (RR-490, RR-492); they live
//! here so the bridge in `relay-rs` and the daemon share one port.
//!
//! A Rust and a Python daemon must be able to take turns on one data root
//! with no migration, so everything that leaves the process is the Python
//! modules' own form: commits on `refs/heads/relay/artifacts` go through
//! `relay-artifacts`, rows through `relay-store`, and every JSON file is
//! written as the Python module writes it.

pub mod authorization;
pub mod command_actions;
pub mod continuity;
pub mod general_work;
pub mod notes;
pub mod personal_storage;
pub mod program;
pub mod program_status;
pub mod providers;

use std::fmt;

pub use relay_intents::json::{Dict, Value};

/// A failure: the Python exception class it corresponds to and its `str()`.
///
/// `state` carries `StorageError.state` for personal storage; it is `None`
/// for every other class.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    pub class: &'static str,
    pub message: String,
    pub state: Option<String>,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(class: &'static str, message: impl Into<String>) -> Self {
        Self {
            class,
            message: message.into(),
            state: None,
        }
    }

    /// A plain `ValueError`.
    pub fn value(message: impl Into<String>) -> Self {
        Self::new("ValueError", message)
    }

    /// A plain `RuntimeError`.
    pub fn runtime(message: impl Into<String>) -> Self {
        Self::new("RuntimeError", message)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for Error {}

impl From<relay_artifacts::Error> for Error {
    fn from(error: relay_artifacts::Error) -> Self {
        Self::new(error.kind.python_class(), error.message)
    }
}

impl From<relay_store::Error> for Error {
    fn from(error: relay_store::Error) -> Self {
        match error {
            relay_store::Error::Invalid(message) => Self::value(message),
            relay_store::Error::Sqlite(error) => Self::new("sqlite3.Error", error.to_string()),
            relay_store::Error::Io(error) => Self::new("OSError", error.to_string()),
            other => Self::new("RuntimeError", other.to_string()),
        }
    }
}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Self::new("OSError", error.to_string())
    }
}

impl From<rusqlite::Error> for Error {
    fn from(error: rusqlite::Error) -> Self {
        Self::new("sqlite3.Error", error.to_string())
    }
}
