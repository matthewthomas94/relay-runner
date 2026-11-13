//! Relay Remote audio in the Mac's voice (RR-457), the twin of
//! `services/remote_audio.py`.
//!
//! A synthesised sentence becomes AAC-LC in ADTS framing, cut into base64
//! parts small enough for one `speech_audio` frame. ADTS needs no container
//! index, so the parts of every sentence of a reply concatenate into one
//! stream the phone can decode as it arrives.
//!
//! The Python speech worker still encodes today; the Rust bridge and speech
//! engine use this module once they host Relay Remote (RR-492).
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use super::protocol::MAX_AUDIO_DATA_BYTES;

pub const AFCONVERT: &str = "/usr/bin/afconvert";
pub const AUDIO_FORMAT: &str = "aac";
/// Kokoro renders 24 kHz mono.
pub const SAMPLE_RATE: i64 = 24000;
/// Constant bit rate: measured about 6.3 KB/s of ADTS on Kokoro speech.
pub const BIT_RATE: i64 = 48000;
pub const ENCODE_TIMEOUT: Duration = Duration::from_secs(15);
/// Raw bytes whose base64 is exactly `MAX_AUDIO_DATA_BYTES`.
const RAW_PART_BYTES: usize = MAX_AUDIO_DATA_BYTES / 4 * 3;

/// `encoder_unavailable` or `encoding_failed`, as the Python twin names them.
#[derive(Debug, PartialEq, Eq)]
pub struct EncodingError(pub &'static str);

/// One `speech_audio` frame's worth of a reply, without its seq.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioPart {
    pub part: i64,
    pub parts: i64,
    pub last: bool,
    pub data: String,
    pub format: String,
    pub sample_rate: i64,
}

pub fn encoder_available() -> bool {
    std::ffi::CString::new(AFCONVERT)
        .map(|path| unsafe { libc::access(path.as_ptr(), libc::X_OK) } == 0)
        .unwrap_or(false)
}

/// Encode a WAV file to AAC-LC ADTS at `SAMPLE_RATE` and `BIT_RATE`.
pub fn encode(wav_path: &Path) -> Result<Vec<u8>, EncodingError> {
    encode_with(AFCONVERT, wav_path, ENCODE_TIMEOUT)
}

fn encode_with(
    encoder: &str,
    wav_path: &Path,
    timeout: Duration,
) -> Result<Vec<u8>, EncodingError> {
    let folder = TemporaryFolder::create().map_err(|_| EncodingError("encoder_unavailable"))?;
    let output = folder.0.join("speech.aac");
    let mut child = Command::new(encoder)
        .args([
            "-f",
            "adts",
            "-d",
            &format!("aac@{SAMPLE_RATE}"),
            "-b",
            &BIT_RATE.to_string(),
            "-s",
            "0",
        ])
        .arg(wav_path)
        .arg(&output)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| EncodingError("encoder_unavailable"))?;
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(EncodingError("encoder_unavailable"));
            }
        }
    };
    if !status.success() || !output.is_file() {
        return Err(EncodingError("encoding_failed"));
    }
    match std::fs::read(&output) {
        Ok(data) if !data.is_empty() => Ok(data),
        _ => Err(EncodingError("encoding_failed")),
    }
}

/// Consecutive base64 slices, each at most `MAX_AUDIO_DATA_BYTES`.
pub fn split(data: &[u8]) -> Vec<String> {
    data.chunks(RAW_PART_BYTES).map(base64).collect()
}

/// Standard base64 with padding, as Python's `base64.b64encode`.
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let triple = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for index in 0..4 {
            if index <= chunk.len() {
                out.push(ALPHABET[(triple >> (18 - 6 * index) & 0x3f) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// `tempfile.TemporaryDirectory(prefix="relay-remote-audio-")`, removed on drop.
struct TemporaryFolder(PathBuf);

impl TemporaryFolder {
    fn create() -> std::io::Result<Self> {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|elapsed| elapsed.as_nanos())
            .unwrap_or_default();
        loop {
            let name = format!(
                "relay-remote-audio-{}-{nanos}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::Relaxed)
            );
            let path = std::env::temp_dir().join(name);
            match std::fs::create_dir(&path) {
                Ok(()) => {
                    use std::os::unix::fs::PermissionsExt;
                    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))?;
                    return Ok(Self(path));
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
    }
}

impl Drop for TemporaryFolder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_python() {
        // RFC 4648 section 10, which `base64.b64encode` follows.
        for (raw, encoded) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(base64(raw.as_bytes()), encoded);
        }
        assert_eq!(base64(&[0xff, 0xf1, 0x60, 0x40]), "//FgQA==");
    }

    #[test]
    fn split_cuts_full_parts_and_a_remainder() {
        let data: Vec<u8> = (0..RAW_PART_BYTES * 2 + 5)
            .map(|index| index as u8)
            .collect();
        let parts = split(&data);
        assert_eq!(
            parts.iter().map(String::len).collect::<Vec<_>>(),
            [MAX_AUDIO_DATA_BYTES, MAX_AUDIO_DATA_BYTES, 8]
        );
        assert_eq!(parts[0], base64(&data[..RAW_PART_BYTES]));
        assert!(split(&[]).is_empty());
    }

    fn write_wav(path: &Path, samples: usize) {
        let data_bytes = (samples * 2) as u32;
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data_bytes).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&24000u32.to_le_bytes());
        wav.extend_from_slice(&48000u32.to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_bytes.to_le_bytes());
        for index in 0..samples {
            let sample = ((index as f64 * 0.05).sin() * 8000.0) as i16;
            wav.extend_from_slice(&sample.to_le_bytes());
        }
        std::fs::write(path, wav).unwrap();
    }

    #[test]
    fn encode_produces_adts() {
        if !encoder_available() {
            return;
        }
        let folder = TemporaryFolder::create().unwrap();
        let wav = folder.0.join("input.wav");
        write_wav(&wav, 24000);
        let data = encode(&wav).unwrap();
        // ADTS sync word.
        assert_eq!(data[0], 0xff);
        assert_eq!(data[1] & 0xf0, 0xf0);
    }

    #[test]
    fn encode_reports_failures_by_their_python_names() {
        let folder = TemporaryFolder::create().unwrap();
        let missing = folder.0.join("missing.wav");
        assert_eq!(
            encode_with("/nonexistent/afconvert", &missing, ENCODE_TIMEOUT),
            Err(EncodingError("encoder_unavailable"))
        );
        assert_eq!(
            encode_with("/usr/bin/false", &missing, ENCODE_TIMEOUT),
            Err(EncodingError("encoding_failed"))
        );
    }
}
