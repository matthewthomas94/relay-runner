//! A failed route, and the status `Handler._route` answers it with.
//!
//! Python picks the status from the exception class with one `except` chain
//! (docs/specs/orchestrator-http-api.md, "Errors"). Every Rust failure keeps
//! the Python class it stands for, so the chain is applied in the same order:
//! a class that is both an `ArtifactValidationError` and a `RuntimeError`
//! answers 422, a `StorageError` 409 before the `ValueError` it also is.
//! A class the chain does not name escapes the handler, and the daemon
//! closes the connection without an answer ([`Class::Escape`]).

use std::fmt;

use relay_intents::json::{Dict, Value};

/// The Python exception family a failure belongs to, in `except` order.
#[derive(Clone, Debug, PartialEq)]
pub enum Class {
    /// `ArtifactRolloutError` (and `ArtifactRolloutBlocked`): 409.
    Rollout {
        code: Option<String>,
        recovery: Option<String>,
    },
    /// `ArtifactConcurrentUpdate`: 409, retryable.
    Concurrent,
    /// `ArtifactEventCollision`, `ArtifactIdentityError`: 409, not retryable.
    Collision,
    /// `ArtifactMaterializationConflict`: 409 `materialization_conflict`.
    Materialization,
    /// `ArtifactValidationError`: 422.
    Validation,
    /// `personal_file_storage.StorageError`: 409 with `state`.
    Storage { state: Option<String> },
    /// `ValueError` and its subclasses: 400.
    Value,
    /// `ProgramRefreshUnavailable`: 503, retryable.
    ProgramRefresh,
    /// `RuntimeError` and its other subclasses: 500.
    Runtime,
    /// `OSError` or `sqlite3.Error`: 503 with a fixed message.
    Io,
    /// Anything else (`KeyError`, `TypeError`, ...): no answer at all.
    Escape,
}

/// A route failure: its class and Python's `str(error)`.
#[derive(Clone, Debug, PartialEq)]
pub struct Failure {
    pub class: Class,
    pub message: String,
}

pub type Outcome<T> = Result<T, Failure>;

/// The fixed answer to an I/O failure; Python never shows the cause.
pub const IO_MESSAGE: &str = "The local workspace service could not complete I/O; retry shortly.";

impl Failure {
    pub fn new(class: Class, message: impl Into<String>) -> Self {
        Self {
            class,
            message: message.into(),
        }
    }

    /// `ValueError(message)`.
    pub fn value(message: impl Into<String>) -> Self {
        Self::new(Class::Value, message)
    }

    /// `RuntimeError(message)`.
    pub fn runtime(message: impl Into<String>) -> Self {
        Self::new(Class::Runtime, message)
    }

    /// `ArtifactValidationError(message)`.
    pub fn validation(message: impl Into<String>) -> Self {
        Self::new(Class::Validation, message)
    }

    /// An exception the handler does not catch.
    pub fn escape(message: impl Into<String>) -> Self {
        Self::new(Class::Escape, message)
    }

    /// `int(text)`'s `ValueError`.
    pub fn int_literal(text: &str) -> Self {
        Self::value(format!(
            "invalid literal for int() with base 10: {}",
            relay_intents::json::str_repr(text)
        ))
    }

    /// Execution that the daemon's part 5 (RR-498) ports: worker, review
    /// and spike processes. The route answers a `RuntimeError` (500) after
    /// every check that runs before a process would start.
    pub fn execution_deferred(what: &str) -> Self {
        Self::runtime(format!(
            "{what} is not available in the Rust daemon yet; worker execution is ported in RR-498"
        ))
    }

    /// The status and JSON body `Handler._route` answers. `None` is a
    /// failure that escapes the handler: the connection closes unanswered.
    pub fn response(&self) -> Option<(u16, Value)> {
        let mut body = Dict::new();
        let status = match &self.class {
            Class::Rollout { code, recovery } => {
                body.insert("error", self.message.as_str());
                body.insert("error_code", code.clone());
                body.insert("recovery", recovery.clone());
                409
            }
            Class::Concurrent => {
                body.insert("error", self.message.as_str());
                body.insert("retryable", true);
                409
            }
            Class::Collision => {
                body.insert("error", self.message.as_str());
                body.insert("retryable", false);
                409
            }
            Class::Materialization => {
                body.insert("error", self.message.as_str());
                body.insert("error_code", "materialization_conflict");
                body.insert("retryable", false);
                409
            }
            Class::Validation => {
                body.insert("error", self.message.as_str());
                422
            }
            Class::Storage { state } => {
                body.insert("error", self.message.as_str());
                body.insert("state", state.clone());
                409
            }
            Class::Value => {
                body.insert("error", self.message.as_str());
                400
            }
            Class::ProgramRefresh => {
                body.insert("error", self.message.as_str());
                body.insert("retryable", true);
                503
            }
            Class::Runtime => {
                body.insert("error", self.message.as_str());
                500
            }
            Class::Io => {
                body.insert("error", IO_MESSAGE);
                body.insert("retryable", true);
                503
            }
            Class::Escape => return None,
        };
        Some((status, Value::Dict(body)))
    }
}

impl fmt::Display for Failure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for Failure {}

/// The family of a Python class name, as `relay_services::Error` and the
/// artifact crate's `ErrorKind::python_class` spell it.
fn class_of(name: &str) -> Class {
    match name {
        "ArtifactRolloutError" | "ArtifactRolloutBlocked" => Class::Rollout {
            code: None,
            recovery: None,
        },
        "ArtifactConcurrentUpdate" => Class::Concurrent,
        "ArtifactEventCollision" | "ArtifactIdentityError" => Class::Collision,
        "ArtifactMaterializationConflict" => Class::Materialization,
        "ArtifactValidationError" | "DependencyHistoryUnavailable" => Class::Validation,
        "StorageError" => Class::Storage { state: None },
        "ValueError"
        | "TicketParseError"
        | "TOMLDecodeError"
        | "NoteContractError"
        | "CatalogSemanticError"
        | "ProgramStatusError"
        | "SessionCaptureError"
        | "JSONDecodeError"
        | "UnicodeDecodeError"
        | "UnicodeEncodeError" => Class::Value,
        "ProgramRefreshUnavailable" => Class::ProgramRefresh,
        "RuntimeError"
        | "ArtifactStoreError"
        | "ArtifactStoreDisabled"
        | "ArtifactInjectedFailure"
        | "ArtifactMigrationError"
        | "ArtifactMigrationBlocked"
        | "ArtifactMigrationReconciliationRequired"
        | "ArtifactMigrationInjectedFailure"
        | "ArtifactVerificationError"
        | "ProgramArtifactError"
        | "ProgramArtifactMigrationError"
        | "CodexModelResolutionError"
        | "NotImplementedError"
        | "RecursionError" => Class::Runtime,
        "OSError"
        | "sqlite3.Error"
        | "FileNotFoundError"
        | "PermissionError"
        | "TimeoutError"
        | "subprocess.TimeoutExpired" => Class::Io,
        _ => Class::Escape,
    }
}

impl From<relay_artifacts::Error> for Failure {
    fn from(error: relay_artifacts::Error) -> Self {
        let class = match class_of(error.kind.python_class()) {
            Class::Rollout { .. } => Class::Rollout {
                code: error.code.clone(),
                recovery: error.recovery.clone(),
            },
            other => other,
        };
        Self::new(class, error.message)
    }
}

impl From<relay_services::Error> for Failure {
    fn from(error: relay_services::Error) -> Self {
        let class = match class_of(error.class) {
            Class::Storage { .. } => Class::Storage { state: error.state },
            other => other,
        };
        Self::new(class, error.message)
    }
}

impl From<relay_store::Error> for Failure {
    fn from(error: relay_store::Error) -> Self {
        match error {
            relay_store::Error::Invalid(message) => Self::value(message),
            relay_store::Error::Sqlite(error) => Self::new(Class::Io, error.to_string()),
            relay_store::Error::Io(error) => Self::new(Class::Io, error.to_string()),
            other => Self::runtime(other.to_string()),
        }
    }
}

impl From<std::io::Error> for Failure {
    fn from(error: std::io::Error) -> Self {
        Self::new(Class::Io, error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(failure: Failure) -> Option<u16> {
        failure.response().map(|(status, _)| status)
    }

    #[test]
    fn classes_answer_in_the_handler_order() {
        let artifact = |kind| relay_artifacts::Error::new(kind, "refused");
        use relay_artifacts::ErrorKind as Kind;
        assert_eq!(status(artifact(Kind::Validation).into()), Some(422));
        assert_eq!(
            status(artifact(Kind::DependencyHistoryUnavailable).into()),
            Some(422)
        );
        assert_eq!(status(artifact(Kind::ConcurrentUpdate).into()), Some(409));
        assert_eq!(status(artifact(Kind::Store).into()), Some(500));
        assert_eq!(status(artifact(Kind::TicketParse).into()), Some(400));
        assert_eq!(status(artifact(Kind::Io).into()), Some(503));
        assert_eq!(status(artifact(Kind::Type).into()), None);
        let storage = relay_services::Error {
            class: "StorageError",
            message: "offline".into(),
            state: Some("offline".into()),
        };
        let (code, body) = Failure::from(storage).response().unwrap();
        assert_eq!(code, 409);
        assert_eq!(body.as_dict().unwrap().string("state"), "offline");
    }

    #[test]
    fn rollout_failures_carry_their_code_and_recovery() {
        let error = relay_artifacts::Error::new(relay_artifacts::ErrorKind::RolloutBlocked, "no")
            .with_code("paused")
            .with_recovery("resume");
        let (code, body) = Failure::from(error).response().unwrap();
        assert_eq!(code, 409);
        let body = body.as_dict().unwrap();
        assert_eq!(body.string("error_code"), "paused");
        assert_eq!(body.string("recovery"), "resume");
    }

    #[test]
    fn io_failures_hide_their_cause() {
        let failure = Failure::from(std::io::Error::other("disk"));
        let (code, body) = failure.response().unwrap();
        assert_eq!(code, 503);
        assert_eq!(body.as_dict().unwrap().string("error"), IO_MESSAGE);
    }

    #[test]
    fn int_literal_names_the_text_as_python_does() {
        assert_eq!(
            Failure::int_literal("abc").message,
            "invalid literal for int() with base 10: 'abc'"
        );
    }
}
