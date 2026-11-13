//! Relay Remote audio in the Mac's voice (RR-457), as `services/remote_audio.py`
//! makes it: a sentence becomes AAC-LC in ADTS framing through
//! `/usr/bin/afconvert`, cut into base64 parts small enough for one
//! `speech_audio` frame. ADTS needs no container index, so the parts of every
//! sentence of a reply concatenate into one stream the phone decodes as it
//! arrives.

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::synth::{Audio, write_wav};

pub const AFCONVERT: &str = "/usr/bin/afconvert";
const SAMPLE_RATE: u32 = 24_000;
/// Constant bit rate: measured about 6.3 KB/s of ADTS on Kokoro speech.
const BIT_RATE: u32 = 48_000;
const ENCODE_TIMEOUT: Duration = Duration::from_secs(15);
/// `MAX_AUDIO_DATA_BYTES` in services/relay_remote_protocol.py.
const MAX_AUDIO_DATA_BYTES: usize = 32 * 1024;
/// Raw bytes whose base64 is exactly `MAX_AUDIO_DATA_BYTES`.
const RAW_PART_BYTES: usize = MAX_AUDIO_DATA_BYTES / 4 * 3;

pub fn encoder_available() -> bool {
    std::ffi::CString::new(AFCONVERT)
        // SAFETY: a valid C string.
        .map(|path| unsafe { libc::access(path.as_ptr(), libc::X_OK) } == 0)
        .unwrap_or(false)
}

/// Encode one sentence to AAC-LC ADTS at 24 kHz and 48 kbit/s.
pub fn encode(audio: &Audio) -> Result<Vec<u8>, &'static str> {
    let folder =
        std::env::temp_dir().join(format!("relay-remote-audio-{}", crate::intent::uuid_hex()));
    std::fs::create_dir(&folder).map_err(|_| "encoder_unavailable")?;
    let result = encode_in(&folder, audio);
    let _ = std::fs::remove_dir_all(&folder);
    result
}

fn encode_in(folder: &std::path::Path, audio: &Audio) -> Result<Vec<u8>, &'static str> {
    let input = folder.join("speech.wav");
    let output = folder.join("speech.aac");
    write_wav(&input, audio).map_err(|_| "encoder_unavailable")?;
    let mut child = Command::new(AFCONVERT)
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
        .arg(&input)
        .arg(&output)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "encoder_unavailable")?;
    let deadline = Instant::now() + ENCODE_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("encoder_unavailable");
            }
        }
    };
    if !status.success() {
        return Err("encoding_failed");
    }
    match std::fs::read(&output) {
        Ok(data) if !data.is_empty() => Ok(data),
        _ => Err("encoding_failed"),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_python() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn parts_fit_one_frame() {
        let data = vec![7u8; RAW_PART_BYTES * 2 + 1];
        let parts = split(&data);
        assert_eq!(parts.len(), 3);
        assert!(parts.iter().all(|part| part.len() <= MAX_AUDIO_DATA_BYTES));
        assert_eq!(parts[0].len(), MAX_AUDIO_DATA_BYTES);
    }

    #[test]
    fn silence_encodes_to_adts() {
        if !encoder_available() {
            return;
        }
        let data = encode(&Audio {
            samples: vec![0; 24_000],
            sample_rate: 24_000,
        })
        .unwrap();
        // An ADTS frame starts with the 12-bit sync word 0xFFF.
        assert_eq!((data[0], data[1] & 0xf0), (0xff, 0xf0));
    }
}
