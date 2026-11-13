//! Reads one voice from `voices-v1.0.bin`, a NumPy `.npz` archive holding one
//! little-endian f32 array of shape (510, 1, 256) per voice: a 256-value style
//! vector for each phoneme count.

use std::fs::File;
use std::io::Read;
use std::path::Path;

pub const STYLE_SIZE: usize = 256;

/// The style vectors of `voice`, one row of `STYLE_SIZE` values per phoneme count.
pub fn load(path: &Path, voice: &str) -> Result<Vec<f32>, Box<dyn std::error::Error>> {
    let mut archive = zip::ZipArchive::new(File::open(path)?)?;
    let mut entry = archive
        .by_name(&format!("{voice}.npy"))
        .map_err(|_| format!("voice {voice} is not in {}", path.display()))?;
    let mut bytes = Vec::new();
    entry.read_to_end(&mut bytes)?;

    // NPY version 1: magic, two version bytes, a u16 header length, the header.
    if bytes.len() < 10 || &bytes[..8] != b"\x93NUMPY\x01\x00" {
        return Err(format!("{voice}.npy is not a version 1 NPY file").into());
    }
    let data = 10 + usize::from(u16::from_le_bytes([bytes[8], bytes[9]]));
    let header = String::from_utf8_lossy(bytes.get(10..data).ok_or("truncated NPY header")?);
    if !header.contains("'descr': '<f4'") || !header.contains(", 1, 256)") {
        return Err(format!("unexpected layout for {voice}.npy: {}", header.trim()).into());
    }
    Ok(bytes[data..]
        .chunks_exact(4)
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect())
}
