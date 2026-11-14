//! Small standard-library pieces the Python note and storage modules use:
//! `base64`, `hashlib.sha1`, `uuid.uuid4().hex` and
//! `datetime.now(timezone.utc).isoformat()`.

use std::fs::File;
use std::io::Read;
use std::time::{SystemTime, UNIX_EPOCH};

const STANDARD: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const URLSAFE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn encode_with(content: &[u8], alphabet: &[u8; 64]) -> String {
    let mut out = String::with_capacity(content.len().div_ceil(3) * 4);
    for chunk in content.chunks(3) {
        let bytes = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let group = (u32::from(bytes[0]) << 16) | (u32::from(bytes[1]) << 8) | u32::from(bytes[2]);
        for index in 0..4 {
            if index <= chunk.len() {
                out.push(alphabet[((group >> (18 - 6 * index)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// `base64.b64encode(content).decode()`.
pub fn b64encode(content: &[u8]) -> String {
    encode_with(content, STANDARD)
}

/// `base64.urlsafe_b64encode(content).decode()`.
pub fn urlsafe_b64encode(content: &[u8]) -> String {
    encode_with(content, URLSAFE)
}

fn decode_with(text: &str, alphabet: &[u8; 64], validate: bool) -> Option<Vec<u8>> {
    let mut values = Vec::with_capacity(text.len());
    let mut padding = 0;
    for byte in text.bytes() {
        if byte == b'=' {
            padding += 1;
            continue;
        }
        match alphabet.iter().position(|candidate| *candidate == byte) {
            // Python's non-validating decode drops characters outside the
            // alphabet; a data character after padding is an error.
            Some(_) if padding > 0 => return None,
            Some(value) => values.push(value as u32),
            None if validate => return None,
            None => {}
        }
    }
    if values.len() % 4 == 1 {
        return None;
    }
    if validate && (values.len() + padding) % 4 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(values.len() * 3 / 4);
    for chunk in values.chunks(4) {
        let mut group = 0u32;
        for (index, value) in chunk.iter().enumerate() {
            group |= value << (18 - 6 * index);
        }
        let produced = chunk.len() * 6 / 8;
        for index in 0..produced {
            out.push((group >> (16 - 8 * index)) as u8);
        }
    }
    Some(out)
}

/// `base64.b64decode(text, validate=True)`, or `None` where Python raises.
pub fn b64decode_strict(text: &str) -> Option<Vec<u8>> {
    decode_with(text, STANDARD, true)
}

/// `base64.b64decode(text)`, or `None` where Python raises.
pub fn b64decode(text: &str) -> Option<Vec<u8>> {
    decode_with(text, STANDARD, false)
}

/// `base64.urlsafe_b64decode(text)`, or `None` where Python raises.
pub fn urlsafe_b64decode(text: &str) -> Option<Vec<u8>> {
    decode_with(text, URLSAFE, false)
}

/// `hashlib.sha1(data).hexdigest()` (FIPS 180-4). Used for Git blob ids.
pub fn sha1_hex(data: &[u8]) -> String {
    let mut state: [u32; 5] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    let mut message = data.to_vec();
    let bit_length = (data.len() as u64).wrapping_mul(8);
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_length.to_be_bytes());
    for block in message.chunks_exact(64) {
        let mut w = [0u32; 80];
        for (index, word) in block.chunks_exact(4).enumerate() {
            w[index] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for index in 16..80 {
            w[index] = (w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = state;
        for (index, word) in w.iter().enumerate() {
            let (f, k) = match index {
                0..=19 => ((b & c) | (!b & d), 0x5A827999),
                20..=39 => (b ^ c ^ d, 0x6ED9EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
                _ => (b ^ c ^ d, 0xCA62C1D6),
            };
            let next = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*word);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = next;
        }
        for (slot, value) in state.iter_mut().zip([a, b, c, d, e]) {
            *slot = slot.wrapping_add(value);
        }
    }
    state.iter().map(|word| format!("{word:08x}")).collect()
}

/// `hashlib.sha1(f"blob {len}\0" + content).hexdigest()`: the Git blob id.
pub fn git_blob_id(content: &[u8]) -> String {
    let mut data = format!("blob {}\0", content.len()).into_bytes();
    data.extend_from_slice(content);
    sha1_hex(&data)
}

fn random_bytes() -> [u8; 16] {
    let mut bytes = [0u8; 16];
    let read = File::open("/dev/urandom").and_then(|mut source| source.read_exact(&mut bytes));
    if read.is_err() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        bytes = (nanos ^ (u128::from(std::process::id()) << 64)).to_le_bytes();
    }
    bytes
}

/// `uuid.uuid4().hex`.
pub fn uuid4_hex() -> String {
    let mut bytes = random_bytes();
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `time.time()`.
pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

/// The proleptic Gregorian date of a day count from 1970-01-01.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if month <= 2 { year + 1 } else { year }, month, day)
}

/// `datetime.fromtimestamp(seconds, timezone.utc).isoformat()` for
/// microseconds since the epoch.
pub fn utc_isoformat_micros(micros: i64) -> String {
    let seconds = micros.div_euclid(1_000_000);
    let fraction = micros.rem_euclid(1_000_000);
    let (year, month, day) = civil_from_days(seconds.div_euclid(86_400));
    let of_day = seconds.rem_euclid(86_400);
    let base = format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}",
        of_day / 3600,
        (of_day / 60) % 60,
        of_day % 60
    );
    if fraction == 0 {
        format!("{base}+00:00")
    } else {
        format!("{base}.{fraction:06}+00:00")
    }
}

/// `datetime.now(timezone.utc).isoformat()`.
pub fn utc_now_isoformat() -> String {
    let micros = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_micros() as i64);
    utc_isoformat_micros(micros)
}

/// `shutil.which(name)`: the first executable regular file on `PATH`.
pub fn which(name: &str) -> Option<std::path::PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(name))
        .find(|candidate| {
            std::fs::metadata(candidate).is_ok_and(|metadata| {
                metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
            })
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_python() {
        assert_eq!(b64encode(b""), "");
        assert_eq!(b64encode(b"f"), "Zg==");
        assert_eq!(b64encode(b"fo"), "Zm8=");
        assert_eq!(b64encode(b"foo"), "Zm9v");
        assert_eq!(urlsafe_b64encode(&[0xfb, 0xff]), "-_8=");
        assert_eq!(b64decode_strict("Zm8=").unwrap(), b"fo");
        assert!(b64decode_strict("Zm8").is_none());
        assert!(b64decode_strict("Zm\n8=").is_none());
        assert_eq!(b64decode("Zm\n8=").unwrap(), b"fo");
        assert_eq!(urlsafe_b64decode("-_8=").unwrap(), vec![0xfb, 0xff]);
    }

    #[test]
    fn digests_and_times() {
        assert_eq!(sha1_hex(b"abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
        // `git hash-object` of an empty file.
        assert_eq!(git_blob_id(b""), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
        assert_eq!(utc_isoformat_micros(0), "1970-01-01T00:00:00+00:00");
        assert_eq!(
            utc_isoformat_micros(1_785_819_600_000_001),
            "2026-08-04T05:00:00.000001+00:00"
        );
        let hex = uuid4_hex();
        assert_eq!(hex.len(), 32);
        assert_eq!(&hex[12..13], "4");
    }
}
