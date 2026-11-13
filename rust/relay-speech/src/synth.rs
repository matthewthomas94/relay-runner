//! What the worker renders sentences with: Kokoro in a session, silence in the
//! contract suite's test mode. Audio stays in memory as 16-bit PCM; only Relay
//! Remote encoding and the Settings preview write WAV files.

use std::path::Path;

use crate::kokoro::{self, Kokoro};

/// Mono 16-bit PCM.
#[derive(Clone, Debug, PartialEq)]
pub struct Audio {
    pub samples: Vec<i16>,
    pub sample_rate: u32,
}

impl Audio {
    pub fn seconds(&self) -> f64 {
        self.samples.len() as f64 / f64::from(self.sample_rate)
    }
}

pub trait Synthesizer: Send + Sync {
    /// A voice is loaded, so sentences can be rendered.
    fn loaded(&self) -> bool;
    /// `Ok(None)` when the text gives no audio; `Err` carries a fixed,
    /// text-free reason.
    fn render(&self, text: &str, voice: &str) -> Result<Option<Audio>, String>;
}

/// `(clip(samples, -1, 1) * 32767).astype(int16)`, refusing non-finite audio.
pub fn to_pcm16(samples: &[f32]) -> Result<Vec<i16>, String> {
    if samples.iter().any(|sample| !sample.is_finite()) {
        return Err("invalid_audio".into());
    }
    Ok(samples
        .iter()
        .map(|sample| (sample.clamp(-1.0, 1.0) * 32767.0) as i16)
        .collect())
}

/// 16-bit PCM WAV bytes.
pub fn wav_bytes(audio: &Audio) -> Vec<u8> {
    let data_bytes = (audio.samples.len() * 2) as u32;
    let mut wav = Vec::with_capacity(44 + audio.samples.len() * 2);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&1_u16.to_le_bytes()); // mono
    wav.extend_from_slice(&audio.sample_rate.to_le_bytes());
    wav.extend_from_slice(&(audio.sample_rate * 2).to_le_bytes()); // bytes per second
    wav.extend_from_slice(&2_u16.to_le_bytes()); // bytes per frame
    wav.extend_from_slice(&16_u16.to_le_bytes()); // bits per sample
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_bytes.to_le_bytes());
    for sample in &audio.samples {
        wav.extend_from_slice(&sample.to_le_bytes());
    }
    wav
}

pub fn write_wav(path: &Path, audio: &Audio) -> std::io::Result<()> {
    std::fs::write(path, wav_bytes(audio))
}

/// Kokoro, or nothing when the model could not be found or loaded.
pub struct KokoroSynth {
    kokoro: Option<Kokoro>,
}

impl KokoroSynth {
    /// Find the model, downloading it when `download` allows, and load it.
    pub fn load(download: bool) -> Self {
        let paths = kokoro::find_model().or_else(|| {
            if download {
                kokoro::download_model()
            } else {
                None
            }
        });
        let Some((model, voices)) = paths else {
            eprintln!("[relay_speech] Warning: could not find or download Kokoro model");
            return Self { kokoro: None };
        };
        match Kokoro::load(&model, &voices) {
            Ok(kokoro) => {
                eprintln!("[relay_speech] Loaded Kokoro model: {}", model.display());
                Self {
                    kokoro: Some(kokoro),
                }
            }
            Err(error) => {
                eprintln!("[relay_speech] Failed to load Kokoro: {error}");
                Self { kokoro: None }
            }
        }
    }
}

impl Synthesizer for KokoroSynth {
    fn loaded(&self) -> bool {
        self.kokoro.is_some()
    }

    fn render(&self, text: &str, voice: &str) -> Result<Option<Audio>, String> {
        let Some(kokoro) = &self.kokoro else {
            return Ok(None);
        };
        let samples = kokoro.create(text, voice).map_err(|error| {
            eprintln!("[relay_speech] TTS error: {error}");
            "synthesis_failed".to_string()
        })?;
        if samples.is_empty() {
            return Ok(None);
        }
        Ok(Some(Audio {
            samples: to_pcm16(&samples)?,
            sample_rate: kokoro::SAMPLE_RATE,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn samples_convert_like_numpy() {
        assert_eq!(
            to_pcm16(&[0.0, 1.0, -1.0, 2.0, -2.0, 0.5, -0.5]).unwrap(),
            [0, 32767, -32767, 32767, -32767, 16383, -16383]
        );
        assert!(to_pcm16(&[f32::NAN]).is_err());
    }

    #[test]
    fn wav_header_describes_24_khz_mono_16_bit() {
        let wav = wav_bytes(&Audio {
            samples: vec![1, -1],
            sample_rate: 24_000,
        });
        assert_eq!(wav.len(), 48);
        assert_eq!(&wav[22..24], &1u16.to_le_bytes());
        assert_eq!(&wav[24..28], &24_000u32.to_le_bytes());
        assert_eq!(&wav[44..], &[1, 0, 0xff, 0xff]);
    }
}
