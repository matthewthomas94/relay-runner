//! The voice continuity lane: `services/continuity_incidents.py`,
//! `continuity_agent.py`, `continuity_recovery.py`, the report rules of
//! `continuity_reports.py`, and the daemon's `ContinuityLifecycleAdapter`
//! from `services/orchestrator.py`.
//!
//! The daemon turns allowlisted lifecycle events (`/v1/continuity/observation`)
//! into opaque [`incidents::Observation`]s ([`lifecycle`]); the
//! [`incidents::ContinuityIncidentDetector`] decides when bounded evidence is a
//! stalled or recurring incident and emits its fixed envelope; the
//! [`agent::ContinuityAgentLane`] asks a tool-less provider session which
//! [`recovery`] capability to try, and the component-owned broker validates and
//! runs it; an unresolved result becomes a privacy-safe [`reports`] row with
//! reviewable fix drafts. [`providers`] holds the Codex and Claude launch
//! configuration of the continuity agent.
//!
//! What leaves the process is the Python form: the envelopes, the JSONL audit
//! and incident lines, the report rows and the proposal drafts. A `ValueError`
//! the Python raises is an [`Error`](crate::Error) of that class with the same
//! message.

pub mod agent;
pub mod incidents;
pub mod lifecycle;
pub mod providers;
pub mod recovery;
pub mod reports;

use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use relay_intents::sha256::hex_digest;

use crate::{Error, Result, Value};

/// `_CODE_RE.fullmatch(text)`: `[a-z][a-z0-9_]{0,63}`.
pub fn is_code(text: &str) -> bool {
    let bytes = text.as_bytes();
    (1..=64).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes[1..]
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_')
}

/// `<prefix>[0-9a-f]{length}` in full.
pub fn is_prefixed_hex(text: &str, prefix: &str, length: usize) -> bool {
    text.strip_prefix(prefix).is_some_and(|hex| {
        hex.len() == length
            && hex
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

/// `_RECOVERY_GENERATION_RE.fullmatch(text)`.
fn is_recovery_generation(text: &str) -> bool {
    let bytes = text.as_bytes();
    (1..=128).contains(&bytes.len())
        && bytes[0].is_ascii_alphanumeric()
        && bytes[1..]
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || b".-_:".contains(b))
}

const INVALID_GENERATION: &str = "invalid recovery generation";

/// `normalize_recovery_generation(value)`: the lossless wire identity used by
/// every continuity component; a non-negative integer becomes its digits.
/// `None` is a missing value (Python's `None`).
pub fn normalize_recovery_generation(value: Option<&Value>) -> Result<String> {
    let text = match value {
        Some(Value::Int(number)) if *number >= 0 => number.to_string(),
        Some(Value::BigInt(digits)) if !digits.starts_with('-') => digits.clone(),
        Some(Value::Str(text)) => text.clone(),
        _ => return Err(Error::value(INVALID_GENERATION)),
    };
    generation(&text)
}

/// `normalize_recovery_generation(text)` for a string.
pub fn generation(text: &str) -> Result<String> {
    if is_recovery_generation(text) {
        Ok(text.to_string())
    } else {
        Err(Error::value(INVALID_GENERATION))
    }
}

/// `opaque_identifier(kind, native_value)`: a stable identifier that does not
/// retain the native one. `native_value` is `str(native_value or "")`.
pub fn opaque_identifier(kind: &str, native_value: &str) -> Result<String> {
    if kind != "session" && kind != "command" {
        return Err(Error::value(
            "opaque identifier kind must be session or command",
        ));
    }
    if native_value.is_empty() {
        return Err(Error::value("opaque identifier source must not be empty"));
    }
    let digest = hex_digest(format!("continuity-v1:{kind}:{native_value}").as_bytes());
    Ok(format!("{kind}-{}", &digest[..24]))
}

/// `time.time()`.
pub fn wall_clock() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

/// `time.monotonic()`, in seconds from an arbitrary origin.
pub fn monotonic() -> f64 {
    use std::sync::OnceLock;
    use std::time::Instant;
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    ORIGIN.get_or_init(Instant::now).elapsed().as_secs_f64() + 1.0
}

/// A clock the lane and broker read, `time.monotonic` unless injected.
pub type Clock = Arc<dyn Fn() -> f64 + Send + Sync>;

/// The default [`Clock`].
pub fn monotonic_clock() -> Clock {
    Arc::new(monotonic)
}

/// `threading.Event`: a flag that can be waited on, shared by clones.
#[derive(Clone, Default)]
pub struct Event {
    inner: Arc<(Mutex<bool>, Condvar)>,
}

impl Event {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set(&self) {
        let (flag, signal) = &*self.inner;
        *flag.lock().unwrap_or_else(|poison| poison.into_inner()) = true;
        signal.notify_all();
    }

    pub fn clear(&self) {
        *self
            .inner
            .0
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()) = false;
    }

    pub fn is_set(&self) -> bool {
        *self
            .inner
            .0
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    /// `event.wait(timeout)`: whether the flag was set.
    pub fn wait(&self, timeout: f64) -> bool {
        let (flag, signal) = &*self.inner;
        let guard = flag.lock().unwrap_or_else(|poison| poison.into_inner());
        let timeout = Duration::from_secs_f64(timeout.clamp(0.0, 1.0e9));
        let (guard, _) = signal
            .wait_timeout_while(guard, timeout, |set| !*set)
            .unwrap_or_else(|poison| poison.into_inner());
        *guard
    }

    /// Whether two handles share one flag (`a is b`).
    pub fn same(&self, other: &Event) -> bool {
        Arc::ptr_eq(&self.inner, &other.inner)
    }
}

/// `uuid.uuid4().hex`: 32 random lowercase hex digits.
pub(crate) fn random_hex32() -> String {
    use std::io::Read;
    let mut bytes = [0u8; 16];
    let read = std::fs::File::open("/dev/urandom").and_then(|mut file| file.read_exact(&mut bytes));
    if read.is_err() {
        // A unique fallback: the clock and the process id.
        let seed = format!(
            "{}:{}:{:?}",
            wall_clock(),
            std::process::id(),
            std::thread::current().id()
        );
        return hex_digest(seed.as_bytes())[..32].to_string();
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generations_and_opaque_identifiers() {
        assert_eq!(
            normalize_recovery_generation(Some(&Value::Int(7))).unwrap(),
            "7"
        );
        assert!(normalize_recovery_generation(Some(&Value::Bool(true))).is_err());
        assert!(normalize_recovery_generation(Some(&Value::Int(-1))).is_err());
        assert!(normalize_recovery_generation(None).is_err());
        assert_eq!(generation("gen-1:a.b").unwrap(), "gen-1:a.b");
        assert!(generation("-x").is_err());
        let id = opaque_identifier("session", "app-session-1").unwrap();
        assert!(is_prefixed_hex(&id, "session-", 24));
        assert_eq!(
            opaque_identifier("ticket", "x").unwrap_err().message,
            "opaque identifier kind must be session or command"
        );
        assert!(is_code("restart_bridge") && !is_code("Restart"));
        let hex = random_hex32();
        assert_eq!(hex.len(), 32);
    }

    #[test]
    fn events_wait_and_share() {
        let event = Event::new();
        assert!(!event.wait(0.01));
        let other = event.clone();
        other.set();
        assert!(event.is_set() && event.wait(0.0) && event.same(&other));
        event.clear();
        assert!(!other.is_set());
    }
}
