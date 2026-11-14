//! The orchestrator daemon's ticket, configuration and artifact-store layer,
//! ported from `services/tickets.py`, `followup_tickets.py`, `config.py`,
//! `artifact_store.py` and `artifact_catalog.py` (RR-494), with the parts of
//! `note_contract.py`, `codex_model_catalog.py` and Python's `tomllib` they
//! rely on.
//!
//! A Rust and a Python daemon must be able to take turns on one data root and
//! one project repository, so everything that leaves the process is the
//! Python modules' own form: the commits on `refs/heads/relay/artifacts` are
//! byte for byte the ones Python makes (tree, message, trailers, digests),
//! the materialization metadata and lock files are shared, and the follow-up
//! store opens the same SQLite schema. Where Python's standard library decides
//! what is valid (`tomllib`, `datetime.fromisoformat`, `str.splitlines`,
//! `json`), this crate carries a port of that behaviour rather than a library
//! that accepts a different language, following CPython 3.14, including its
//! error messages. `tests/test_relay_artifacts_parity.py` checks both
//! implementations against each other through `examples/artifacts_driver.rs`,
//! and `tests/contract/test_orchestrator_contract_artifact_crate.py` checks
//! the crate's commits against the RR-485 golden commits.
//!
//! Known differences, each refused or accepted the same way as in Python:
//!
//! - A JSON decode failure is reported without Python's position details
//!   (`Expecting value` rather than `Expecting value: line 1 column 1 (char 0)`).
//! - A lone surrogate escape in note JSON is refused when the note is
//!   written, as Python refuses it, but without the character and position
//!   Python's `UnicodeEncodeError` names.
//! - An integer beyond `i64` is refused where Python's unbounded `int` would
//!   take it: a board's `next_id`, a note segment's offsets.
//! - The follow-up store checks for an existing batch inside its write
//!   transaction (`followup` explains why).

pub mod board_config;
pub mod catalog;
pub mod codex;
pub mod config;
pub mod followup;
pub mod isotime;
pub mod notes;
pub mod paths;
pub mod pystr;
pub mod store;
pub mod tickets;
pub mod toml;

pub mod git;

use std::fmt;

/// Which Python exception a failure corresponds to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorKind {
    /// `tickets.TicketParseError`.
    TicketParse,
    /// A plain `ValueError`, such as `int()` refusing its text.
    Value,
    /// `tomllib.TOMLDecodeError`.
    TomlDecode,
    /// `note_contract.NoteContractError`.
    NoteContract,
    /// `artifact_catalog.CatalogSemanticError`.
    CatalogSemantic,
    /// `OverflowError`, from datetime arithmetic out of range.
    Overflow,
    /// `TypeError`, such as an unhashable value tested against a set.
    Type,
    /// `AttributeError`, such as a string method called on a number.
    Attribute,
    /// `RuntimeError`, such as `Path.expanduser()` without a home.
    Runtime,
    /// `artifact_store.ArtifactStoreError`.
    Store,
    /// `artifact_store.ArtifactStoreDisabled`.
    StoreDisabled,
    /// `artifact_store.ArtifactValidationError`.
    Validation,
    /// `artifact_store.ArtifactIdentityError`.
    Identity,
    /// `artifact_store.ArtifactConcurrentUpdate`.
    ConcurrentUpdate,
    /// `artifact_store.ArtifactEventCollision`.
    EventCollision,
    /// `artifact_store.ArtifactMaterializationConflict`.
    MaterializationConflict,
    /// `artifact_store.ArtifactInjectedFailure`, raised only by test hooks.
    InjectedFailure,
    /// `OSError`.
    Io,
    /// `sqlite3.Error`.
    Sqlite,
}

impl ErrorKind {
    /// The Python class name, as the parity driver reports it.
    pub fn python_class(self) -> &'static str {
        match self {
            ErrorKind::TicketParse => "TicketParseError",
            ErrorKind::Value => "ValueError",
            ErrorKind::TomlDecode => "TOMLDecodeError",
            ErrorKind::NoteContract => "NoteContractError",
            ErrorKind::CatalogSemantic => "CatalogSemanticError",
            ErrorKind::Overflow => "OverflowError",
            ErrorKind::Type => "TypeError",
            ErrorKind::Attribute => "AttributeError",
            ErrorKind::Runtime => "RuntimeError",
            ErrorKind::Store => "ArtifactStoreError",
            ErrorKind::StoreDisabled => "ArtifactStoreDisabled",
            ErrorKind::Validation => "ArtifactValidationError",
            ErrorKind::Identity => "ArtifactIdentityError",
            ErrorKind::ConcurrentUpdate => "ArtifactConcurrentUpdate",
            ErrorKind::EventCollision => "ArtifactEventCollision",
            ErrorKind::MaterializationConflict => "ArtifactMaterializationConflict",
            ErrorKind::InjectedFailure => "ArtifactInjectedFailure",
            ErrorKind::Io => "OSError",
            ErrorKind::Sqlite => "sqlite3.Error",
        }
    }
}

/// A failure: the Python exception class and its `str()`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    pub kind: ErrorKind,
    pub message: String,
}

impl Error {
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    pub(crate) fn value(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Value, message)
    }

    /// The same message under another class, as `raise B(str(a)) from a`.
    pub(crate) fn recast(self, kind: ErrorKind) -> Self {
        Self { kind, ..self }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Error::new(ErrorKind::Io, error.to_string())
    }
}

impl From<rusqlite::Error> for Error {
    fn from(error: rusqlite::Error) -> Self {
        Error::new(ErrorKind::Sqlite, error.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;
