//! Small pieces the speech service shares: clocks, Python-compatible JSON,
//! the event log, the audio lease and the overlay's state datagrams.

use std::ffi::CString;
use std::io::Write;
use std::os::unix::net::UnixDatagram;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value};

pub type Json = Map<String, Value>;

/// Unix time in seconds, as Python's `time.time()`.
pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

unsafe extern "C" {
    fn clock_gettime_nsec_np(clock: libc::clockid_t) -> u64;
}

/// Monotonic nanoseconds that never allocate or lock, for the refill callback.
pub fn monotonic_nanos() -> u64 {
    // SAFETY: a plain clock read.
    unsafe { clock_gettime_nsec_np(libc::CLOCK_UPTIME_RAW) }
}

pub fn elapsed_ms(started: Instant) -> f64 {
    (started.elapsed().as_secs_f64() * 1000.0 * 1000.0).round() / 1000.0
}

pub fn duration_ms(started: Option<f64>, ended: Option<f64>) -> Value {
    match (started, ended) {
        (Some(started), Some(ended)) => {
            number((((ended - started) * 1000.0) * 1000.0).round() / 1000.0)
        }
        _ => Value::Null,
    }
}

pub fn number(value: f64) -> Value {
    serde_json::Number::from_f64(value).map_or(Value::Null, Value::Number)
}

pub fn opt_text(value: Option<&str>) -> Value {
    value.map_or(Value::Null, |text| Value::String(text.to_string()))
}

pub fn opt_int(value: Option<i64>) -> Value {
    value.map_or(Value::Null, |number| Value::Number(number.into()))
}

pub fn sleep(seconds: f64) {
    std::thread::sleep(Duration::from_secs_f64(seconds.max(0.0)));
}

/// `json.dumps(value)` with Python's defaults: `", "` and `": "` separators
/// and every non-ASCII character escaped. The state datagram limit is counted
/// in this encoding, as the overlay's Python peers count it.
pub fn python_dumps(value: &Value) -> String {
    let mut out = String::new();
    write_python(value, &mut out);
    out
}

fn write_python(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => out.push_str(&number.to_string()),
        Value::String(text) => write_python_string(text, out),
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push_str(", ");
                }
                write_python(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            out.push('{');
            for (index, (key, item)) in map.iter().enumerate() {
                if index > 0 {
                    out.push_str(", ");
                }
                write_python_string(key, out);
                out.push_str(": ");
                write_python(item, out);
            }
            out.push('}');
        }
    }
}

fn write_python_string(text: &str, out: &mut String) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if c.is_ascii() && !c.is_ascii_control() => out.push(c),
            c => {
                let mut units = [0u16; 2];
                for unit in c.encode_utf16(&mut units) {
                    out.push_str(&format!("\\u{unit:04x}"));
                }
            }
        }
    }
    out.push('"');
}

/// Append one JSON object per line; a write that fails is dropped.
pub struct JsonLog {
    path: Option<PathBuf>,
    lock: Mutex<()>,
}

impl JsonLog {
    pub fn new(path: Option<PathBuf>) -> Self {
        Self {
            path,
            lock: Mutex::new(()),
        }
    }

    pub fn enabled(&self) -> bool {
        self.path.is_some()
    }

    pub fn write(&self, record: &Json) {
        let Some(path) = &self.path else { return };
        let mut line = serde_json::to_string(record).unwrap_or_default();
        line.push('\n');
        let _guard = self.lock.lock();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            let _ = file.write_all(line.as_bytes());
        }
    }
}

/// `voice-audio.lock`, held with `flock` while audio plays, so a Settings voice
/// preview and a reply never overlap (`services/voice_audio_lease.py`).
pub struct AudioLease {
    fd: libc::c_int,
}

#[derive(Debug, PartialEq, Eq)]
pub enum LeaseError {
    Cancelled,
    Busy,
    Unavailable,
}

impl AudioLease {
    pub fn acquire(cancelled: &dyn Fn() -> bool, timeout: Duration) -> Result<Self, LeaseError> {
        Self::acquire_in(&crate::config::support_root(), cancelled, timeout)
    }

    pub fn acquire_in(
        root: &Path,
        cancelled: &dyn Fn() -> bool,
        timeout: Duration,
    ) -> Result<Self, LeaseError> {
        let _ = std::fs::DirBuilder::new()
            .recursive(true)
            .mode_0700()
            .create(root);
        let path = CString::new(root.join("voice-audio.lock").as_os_str().as_encoded_bytes())
            .map_err(|_| LeaseError::Unavailable)?;
        // SAFETY: a valid C string and plain flags.
        let fd = unsafe {
            libc::open(
                path.as_ptr(),
                libc::O_CREAT | libc::O_RDWR | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(LeaseError::Unavailable);
        }
        let deadline = Instant::now() + timeout;
        loop {
            if cancelled() {
                // SAFETY: fd is ours.
                unsafe { libc::close(fd) };
                return Err(LeaseError::Cancelled);
            }
            // SAFETY: fd is open.
            if unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                return Ok(Self { fd });
            }
            if Instant::now() >= deadline {
                // SAFETY: fd is ours.
                unsafe { libc::close(fd) };
                return Err(LeaseError::Busy);
            }
            sleep(0.025);
        }
    }
}

impl Drop for AudioLease {
    fn drop(&mut self) {
        // SAFETY: closing the descriptor releases the lock.
        unsafe { libc::close(self.fd) };
    }
}

trait DirBuilderMode {
    fn mode_0700(&mut self) -> &mut Self;
}

impl DirBuilderMode for std::fs::DirBuilder {
    fn mode_0700(&mut self) -> &mut Self {
        std::os::unix::fs::DirBuilderExt::mode(self, 0o700)
    }
}

/// macOS refuses a Unix datagram over `net.local.dgram.maxdgram` (2048 bytes by
/// default) with EMSGSIZE, so a long reply preview would never reach the overlay.
pub const MAX_STATE_DATAGRAM_BYTES: usize = 2048;

/// Encode a state update, shortening its preview text until the datagram fits.
pub fn state_datagram(message: &Json) -> Vec<u8> {
    let mut data = python_dumps(&Value::Object(message.clone()));
    let mut text: Option<Vec<char>> = match message.get("text") {
        Some(Value::String(text)) => Some(text.chars().collect()),
        _ => None,
    };
    while data.len() > MAX_STATE_DATAGRAM_BYTES {
        let Some(chars) = text.as_mut().filter(|chars| !chars.is_empty()) else {
            break;
        };
        // Every dropped character frees at least one encoded byte.
        let keep = chars
            .len()
            .saturating_sub(data.len() - MAX_STATE_DATAGRAM_BYTES + 1);
        chars.truncate(keep);
        while chars
            .last()
            .is_some_and(|c| crate::sentences::is_py_space(*c))
        {
            chars.pop();
        }
        let mut shortened = message.clone();
        let mut preview: String = chars.iter().collect();
        preview.push('…');
        shortened.insert("text".into(), Value::String(preview));
        data = python_dumps(&Value::Object(shortened));
    }
    data.into_bytes()
}

/// The overlay's state socket and whether this process is the tutorial voice.
pub struct StateSocket {
    path: PathBuf,
    tutorial: bool,
}

impl StateSocket {
    pub fn from_environment(tutorial: bool) -> Self {
        let path = std::env::var_os("VOICE_STATE_SOCK")
            .filter(|path| !path.is_empty())
            .map_or_else(|| PathBuf::from("/tmp/voice_state.sock"), PathBuf::from);
        Self { path, tutorial }
    }

    /// Send a state update; silently dropped when the overlay is not listening.
    pub fn notify(&self, state: &str, fields: Json) {
        let mut message = Json::new();
        message.insert("source".into(), "tts".into());
        message.insert("state".into(), state.into());
        message.insert("tutorial".into(), self.tutorial.into());
        message.extend(fields);
        if let Ok(socket) = UnixDatagram::unbound() {
            let _ = socket.send_to(&state_datagram(&message), &self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn python_dumps_matches_json_dumps() {
        let value =
            serde_json::json!({"a": "\u{e9}\u{2026}\"\n", "b": [1, 2.5, null, true], "c": {}});
        assert_eq!(
            python_dumps(&value),
            r#"{"a": "\u00e9\u2026\"\n", "b": [1, 2.5, null, true], "c": {}}"#
        );
        assert_eq!(
            python_dumps(&serde_json::json!("\u{1f600}")),
            r#""\ud83d\ude00""#
        );
    }

    #[test]
    fn long_preview_text_is_shortened_to_fit() {
        let text = "A long reply that goes on. ".repeat(200);
        let mut message = Json::new();
        message.insert("source".into(), "tts".into());
        message.insert("text".into(), Value::String(text.trim().to_string()));
        let data = state_datagram(&message);
        assert!(data.len() <= MAX_STATE_DATAGRAM_BYTES);
        let parsed: Json = serde_json::from_slice(&data).unwrap();
        let shortened = parsed["text"].as_str().unwrap();
        assert!(shortened.ends_with('…'));
        assert!(text.starts_with(shortened.trim_end_matches('…')));
        assert!(shortened.len() > 1000);
    }

    #[test]
    fn lease_excludes_a_second_holder_and_releases_on_drop() {
        let root = std::env::temp_dir().join(format!("relay-speech-lease-{}", std::process::id()));
        let first = AudioLease::acquire_in(&root, &|| false, Duration::ZERO).unwrap();
        assert_eq!(
            AudioLease::acquire_in(&root, &|| false, Duration::from_millis(60)).err(),
            Some(LeaseError::Busy)
        );
        assert_eq!(
            AudioLease::acquire_in(&root, &|| true, Duration::from_secs(1)).err(),
            Some(LeaseError::Cancelled)
        );
        drop(first);
        assert!(AudioLease::acquire_in(&root, &|| false, Duration::ZERO).is_ok());
        let _ = std::fs::remove_dir_all(root);
    }
}
