//! Prototype for RR-479, not production code: Kokoro speech synthesis in Rust,
//! to be measured against the Python stack in `services/tts_worker.py`.
//!
//! It follows what kokoro-onnx 0.5.0 does around the model (phoneme filtering,
//! batching, style lookup, silence trim) and replaces its two native parts:
//! ONNX Runtime is driven through `ort`, and phonemes come from one of two
//! non-GPL crates: `misaki-rs` built without espeak-ng, which leaves a word it
//! does not know unspoken, or `loqui-g2p`, which pronounces such a word with a
//! small embedded neural model.
//!
//!     relay-speech-proto --corpus corpus.tsv --voice am_puck --out DIR \
//!         [--g2p misaki|loqui] [--lang us|gb] [--provider cpu|coreml] [--models DIR]
//!
//! Each corpus line is `id<TAB>category<TAB>text`. One WAV per line is written
//! to `--out`, and timings go to stdout as tab-separated lines:
//!
//!     load      model_ms=N  voice_ms=N  g2p_ms=N
//!     sentence  id  g2p_ms  synth_ms  audio_seconds  unknown_words  phonemes

mod trim;
mod vocab;
mod voices;

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;

use ort::session::Session;
use ort::value::Tensor;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const SAMPLE_RATE: u32 = 24_000;
/// The model's context is 512 tokens, two of which are the padding around a batch.
const MAX_PHONEMES: usize = 510;

fn main() -> Result<()> {
    let options = options()?;
    let option = |name: &str| options.get(name).map(String::as_str);
    let required = |name: &str| option(name).ok_or(format!("--{name} is required"));
    let corpus = std::fs::read_to_string(required("corpus")?)?;
    let voice = required("voice")?;
    let out = PathBuf::from(required("out")?);
    let models = match option("models") {
        Some(models) => PathBuf::from(models),
        None => PathBuf::from(std::env::var("HOME")?).join(".local/share/kokoro"),
    };
    let british = match option("lang").unwrap_or("us") {
        "us" => false,
        "gb" => true,
        other => return Err(format!("--lang must be us or gb, not {other}").into()),
    };
    std::fs::create_dir_all(&out)?;

    let started = Instant::now();
    let environment = ort::init().build()?;
    let mut builder = Session::builder(&environment)?;
    match option("provider").unwrap_or("cpu") {
        "cpu" => {}
        "coreml" => {
            let coreml = ort::ep::CoreML::default().build().error_on_failure();
            builder = builder
                .with_execution_providers([coreml])
                .map_err(|error| error.to_string())?;
        }
        other => return Err(format!("--provider must be cpu or coreml, not {other}").into()),
    }
    let mut session = builder.commit_from_file(models.join("kokoro-v1.0.onnx"))?;
    let model_ms = milliseconds(started);

    let started = Instant::now();
    let styles = voices::load(&models.join("voices-v1.0.bin"), voice)?;
    let voice_ms = milliseconds(started);

    let started = Instant::now();
    let g2p = match option("g2p").unwrap_or("misaki") {
        "misaki" => Phonemizer::Misaki(Box::new(misaki_rs::G2P::new(if british {
            misaki_rs::Language::EnglishGB
        } else {
            misaki_rs::Language::EnglishUS
        }))),
        "loqui" => Phonemizer::Loqui(Box::new(loqui_g2p::G2p::new(
            if british {
                loqui_g2p::Dialect::British
            } else {
                loqui_g2p::Dialect::American
            },
            loqui_g2p::OovFallback::Neural,
        )?)),
        other => return Err(format!("--g2p must be misaki or loqui, not {other}").into()),
    };
    let vocab: HashMap<char, i64> = vocab::VOCAB.iter().copied().collect();
    println!(
        "load\tmodel_ms={model_ms:.1}\tvoice_ms={voice_ms:.1}\tg2p_ms={:.1}",
        milliseconds(started)
    );

    for line in corpus.lines().filter(|line| !line.trim().is_empty()) {
        let mut fields = line.splitn(3, '\t');
        let (Some(id), Some(_category), Some(text)) = (fields.next(), fields.next(), fields.next())
        else {
            return Err(format!("corpus line is not id<TAB>category<TAB>text: {line}").into());
        };

        let started = Instant::now();
        let (phonemes, unknown) = g2p.phonemize(text.trim())?;
        // What the model can be fed: a word that could not be resolved is
        // marked with a symbol outside the vocabulary, so it is dropped here.
        let phonemes: String = phonemes
            .chars()
            .filter(|symbol| vocab.contains_key(symbol))
            .collect();
        let phonemes = phonemes.trim();
        let g2p_ms = milliseconds(started);

        let started = Instant::now();
        let mut audio = Vec::new();
        for batch in split_phonemes(phonemes) {
            let tokens: Vec<i64> = batch
                .chars()
                .take(MAX_PHONEMES)
                .map(|symbol| vocab[&symbol])
                .collect();
            audio.extend_from_slice(trim::trim(&synthesize(&mut session, &styles, &tokens)?));
        }
        let synth_ms = milliseconds(started);

        write_wav(&out.join(format!("{id}.wav")), &audio)?;
        println!(
            "sentence\t{id}\t{g2p_ms:.1}\t{synth_ms:.1}\t{:.3}\t{}\t{phonemes}",
            audio.len() as f64 / f64::from(SAMPLE_RATE),
            unknown.join(" "),
        );
        std::io::stdout().flush()?;
    }
    Ok(())
}

enum Phonemizer {
    Misaki(Box<misaki_rs::G2P>),
    Loqui(Box<loqui_g2p::G2p>),
}

impl Phonemizer {
    /// The phonemes of `text`, and the words in it left wholly or partly unspoken.
    fn phonemize(&self, text: &str) -> Result<(String, Vec<String>)> {
        let spoken = |word: &str| word.chars().any(char::is_alphanumeric);
        Ok(match self {
            Self::Misaki(g2p) => {
                let (phonemes, tokens) = g2p.g2p(text)?;
                let unresolved = |phonemes: &Option<String>| {
                    phonemes.as_ref().is_none_or(|ps| ps.contains(&g2p.unk))
                };
                let unknown = tokens
                    .into_iter()
                    .filter(|token| spoken(&token.text) && unresolved(&token.phonemes));
                (phonemes, unknown.map(|token| token.text).collect())
            }
            Self::Loqui(g2p) => {
                let unknown = g2p
                    .tokens(text)
                    .into_iter()
                    .filter(|token| spoken(&token.text) && token.phonemes.is_empty());
                (
                    g2p.phonemize(text),
                    unknown.map(|token| token.text).collect(),
                )
            }
        })
    }
}

/// `--name value` pairs from the command line.
fn options() -> Result<HashMap<String, String>> {
    let mut options = HashMap::new();
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        let name = argument
            .strip_prefix("--")
            .ok_or(format!("unexpected argument {argument}"))?;
        let value = arguments.next().ok_or(format!("--{name} needs a value"))?;
        options.insert(name.to_string(), value);
    }
    Ok(options)
}

fn milliseconds(started: Instant) -> f64 {
    started.elapsed().as_secs_f64() * 1000.0
}

/// kokoro-onnx's `_split_phonemes`: batches of fewer than `MAX_PHONEMES`
/// symbols, broken at punctuation where there is any.
fn split_phonemes(phonemes: &str) -> Vec<String> {
    const BREAKS: &str = ".,!?;";
    let mut parts = Vec::new();
    let mut start = 0;
    for (index, symbol) in phonemes.char_indices() {
        if BREAKS.contains(symbol) {
            parts.push(&phonemes[start..index]);
            parts.push(&phonemes[index..index + symbol.len_utf8()]);
            start = index + symbol.len_utf8();
        }
    }
    parts.push(&phonemes[start..]);

    let mut batches = Vec::new();
    let mut current = String::new();
    for part in parts
        .into_iter()
        .map(str::trim)
        .filter(|part| !part.is_empty())
    {
        if current.chars().count() + part.chars().count() + 1 >= MAX_PHONEMES {
            if !current.is_empty() {
                batches.push(current.trim().to_string());
            }
            current = part.to_string();
        } else {
            if !BREAKS.contains(part) && !current.is_empty() {
                current.push(' ');
            }
            current.push_str(part);
        }
    }
    if !current.is_empty() {
        batches.push(current.trim().to_string());
    }
    batches
}

/// One model call: the batch's tokens between two padding tokens, the voice's
/// style vector for that many tokens, and speed 1.0 as `tts_worker.py` uses.
fn synthesize(session: &mut Session, styles: &[f32], tokens: &[i64]) -> Result<Vec<f32>> {
    let rows = styles.len() / voices::STYLE_SIZE;
    let row = tokens.len().min(rows - 1) * voices::STYLE_SIZE;
    let style = styles[row..row + voices::STYLE_SIZE].to_vec();
    let mut padded = Vec::with_capacity(tokens.len() + 2);
    padded.push(0);
    padded.extend_from_slice(tokens);
    padded.push(0);

    let outputs = session.run(ort::inputs![
        "tokens" => Tensor::from_array(([1, padded.len()], padded))?,
        "style" => Tensor::from_array(([1, voices::STYLE_SIZE], style))?,
        "speed" => Tensor::from_array(([1_usize], vec![1.0_f32]))?,
    ])?;
    let (_, audio) = outputs["audio"].try_extract_tensor::<f32>()?;
    Ok(audio.to_vec())
}

/// 24 kHz mono 16-bit PCM, converted the way `tts_worker.py` converts it.
fn write_wav(path: &Path, samples: &[f32]) -> Result<()> {
    if samples.iter().any(|sample| !sample.is_finite()) {
        return Err(format!("non-finite audio for {}", path.display()).into());
    }
    let data_bytes = u32::try_from(samples.len() * 2)?;
    let mut wav = Vec::with_capacity(44 + samples.len() * 2);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&1_u16.to_le_bytes()); // mono
    wav.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    wav.extend_from_slice(&(SAMPLE_RATE * 2).to_le_bytes()); // bytes per second
    wav.extend_from_slice(&2_u16.to_le_bytes()); // bytes per frame
    wav.extend_from_slice(&16_u16.to_le_bytes()); // bits per sample
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_bytes.to_le_bytes());
    for sample in samples {
        wav.extend_from_slice(&((sample.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
    }
    Ok(std::fs::write(path, wav)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_phonemes_stay_one_batch() {
        assert_eq!(
            split_phonemes("həlˈO, wˈɜɹld! tˈɛst"),
            ["həlˈO, wˈɜɹld! tˈɛst"]
        );
    }

    #[test]
    fn long_phonemes_break_at_punctuation() {
        let clause = "a".repeat(300);
        let batches = split_phonemes(&format!("{clause}, {clause}. {clause}"));
        assert_eq!(
            batches,
            [format!("{clause},"), format!("{clause}."), clause]
        );
    }
}
