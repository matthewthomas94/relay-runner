//! The provider-turn tables in the intent inbox, through the `relay-intents`
//! broker (RR-489), the Rust form of `services/provider_turn_broker.py` that
//! the Python bridge's tables are shared with.
//!
//! What stays here is the hook's own: a locked inbox is waited for only until
//! the hook's deadline, and a failure is named by the exception class the
//! Python hook would have raised.

use std::thread;
use std::time::{Duration, Instant};

use relay_intents::broker;
use relay_intents::database::LockWait;
pub(super) use relay_intents::database::sql_to_json;
use relay_intents::model::TurnState;

use crate::json::Dict;
use crate::support::{self, Failure};

impl From<rusqlite::Error> for Failure {
    fn from(error: rusqlite::Error) -> Self {
        use rusqlite::ErrorCode;
        Failure(match error.sqlite_error_code() {
            Some(ErrorCode::NotADatabase | ErrorCode::DatabaseCorrupt) => "DatabaseError",
            Some(ErrorCode::ConstraintViolation) => "IntegrityError",
            _ => "OperationalError",
        })
    }
}

impl From<relay_intents::Error> for Failure {
    fn from(error: relay_intents::Error) -> Self {
        match error {
            relay_intents::Error::Sqlite(error) => error.into(),
            relay_intents::Error::Io(error) => error.into(),
            relay_intents::Error::Invalid(_) => Failure("ValueError"),
        }
    }
}

/// SQLite's own retry intervals; the wait ends at the hook's deadline, not
/// after the bridge's 5 seconds, so a locked inbox cannot outlast the 2
/// seconds a provider gives a hook.
fn wait_for_lock(attempt: i32) -> bool {
    const DELAYS_MS: [u64; 12] = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100];
    let remaining = support::wait_deadline().saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return false;
    }
    let index = usize::try_from(attempt)
        .unwrap_or(0)
        .min(DELAYS_MS.len() - 1);
    thread::sleep(Duration::from_millis(DELAYS_MS[index]).min(remaining));
    true
}

pub struct ProviderTurnBroker(broker::ProviderTurnBroker);

impl ProviderTurnBroker {
    pub fn open(path: &str, projection_path: &str) -> Result<Self, Failure> {
        let broker = broker::ProviderTurnBroker::open_with(
            path,
            Some(projection_path),
            LockWait::Handler(wait_for_lock),
        )?;
        Ok(Self(broker))
    }

    /// Opens `record` as the active turn of its owner and provider session.
    pub fn activate(&self, record: &Dict, now: f64, release_reason: &str) -> Result<(), Failure> {
        self.0.activate(record, Some(now), release_reason)?;
        Ok(())
    }

    /// Moves the turn `record` names to a terminal state; `false` unless this
    /// call made the move.
    pub fn transition(
        &self,
        record: &Dict,
        to_state: &str,
        event_type: &str,
        release_reason: &str,
        now: f64,
    ) -> Result<bool, Failure> {
        let Some(to_state) = TurnState::parse(to_state) else {
            return Ok(false);
        };
        Ok(self.0.transition(
            record,
            to_state,
            event_type,
            release_reason,
            Some(now),
            None,
        )?)
    }

    pub fn state_for(&self, record: &Dict) -> Result<Option<String>, Failure> {
        Ok(self.0.state_for(record)?)
    }

    pub fn session_records(&self, native_session_id: &str) -> Result<Vec<Dict>, Failure> {
        Ok(self.0.session_records(native_session_id)?)
    }
}
