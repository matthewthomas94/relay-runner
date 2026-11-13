//! Kokoro v1.0 synthesis on ONNX Runtime with loqui-g2p phonemes (RR-479).
//!
//! It does what kokoro-onnx 0.5.0 does around the model, as the prototype in
//! `rust/relay-speech-proto` measured: phonemise, keep the symbols the model
//! knows, split into batches under 510 symbols, pick the voice's style vector
//! for the batch length, run the model at speed 1.0, trim silence. Every voice
//! is phonemised as American English, as the Python stack asks espeak-ng to.
//!
//! The model runs on one thread, which serialises synthesis the way
//! `_synth_lock` does in `services/tts_worker.py`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::sync::mpsc;

use ort::session::Session;
use ort::value::Tensor;

use crate::{trim, vocab, voices};

pub const MODEL_FILE: &str = "kokoro-v1.0.onnx";
pub const VOICES_FILE: &str = "voices-v1.0.bin";
pub const SAMPLE_RATE: u32 = 24_000;
/// `hf_hub_download(repo_id="fastrtc/kokoro-onnx", filename=...)`.
const DOWNLOAD_BASE: &str = "https://huggingface.co/fastrtc/kokoro-onnx/resolve/main";
/// The model's context is 512 tokens, two of which pad the batch.
const MAX_PHONEMES: usize = 510;

/// Where the model is looked for: `$VOICE_MODELS_DIR/kokoro`, then
/// `~/.local/share/kokoro`, as `_find_kokoro_model` searches.
pub fn model_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(bundled) = std::env::var_os("VOICE_MODELS_DIR").filter(|dir| !dir.is_empty()) {
        dirs.push(PathBuf::from(bundled).join("kokoro"));
    }
    dirs.push(download_dir());
    dirs
}

pub fn download_dir() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share/kokoro")
}

pub fn find_model() -> Option<(PathBuf, PathBuf)> {
    model_dirs().into_iter().find_map(|dir| {
        let (model, voices) = (dir.join(MODEL_FILE), dir.join(VOICES_FILE));
        (model.is_file() && voices.is_file()).then_some((model, voices))
    })
}

/// Download the two model files into `~/.local/share/kokoro`, as the Python
/// worker did with huggingface_hub. Each file is written beside its final
/// name and renamed into place, so a broken download never looks complete.
pub fn download_model() -> Option<(PathBuf, PathBuf)> {
    let dir = download_dir();
    if std::fs::create_dir_all(&dir).is_err() {
        eprintln!("[relay_speech] Failed to create {}", dir.display());
        return None;
    }
    eprintln!("[relay_speech] Downloading Kokoro model...");
    for name in [MODEL_FILE, VOICES_FILE] {
        let target = dir.join(name);
        if target.is_file() {
            continue;
        }
        let partial = dir.join(format!("{name}.download"));
        let status = Command::new("/usr/bin/curl")
            .args([
                "--fail",
                "--location",
                "--silent",
                "--show-error",
                "--retry",
                "3",
                "--output",
            ])
            .arg(&partial)
            .arg(format!("{DOWNLOAD_BASE}/{name}"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .status();
        if !status.is_ok_and(|status| status.success())
            || std::fs::rename(&partial, &target).is_err()
        {
            let _ = std::fs::remove_file(&partial);
            eprintln!("[relay_speech] Failed to download {name}");
            return None;
        }
    }
    eprintln!("[relay_speech] Model downloaded: {}", dir.display());
    find_model()
}

type Reply = mpsc::Sender<Result<Vec<f32>, String>>;

struct Job {
    text: String,
    voice: String,
    reply: Reply,
}

/// The loaded model, served by its own thread.
pub struct Kokoro {
    jobs: Mutex<mpsc::Sender<Job>>,
}

impl Kokoro {
    /// Load the model, the phonemiser and the voice table; returns once ready.
    pub fn load(model: &Path, voices_path: &Path) -> Result<Self, String> {
        let (jobs, queue) = mpsc::channel::<Job>();
        let (ready, loaded) = mpsc::channel();
        let (model, voices_path) = (model.to_path_buf(), voices_path.to_path_buf());
        std::thread::Builder::new()
            .name("kokoro".into())
            .spawn(move || match Engine::load(&model, voices_path) {
                Ok(mut engine) => {
                    let _ = ready.send(Ok(()));
                    for job in queue {
                        let _ = job.reply.send(engine.create(&job.text, &job.voice));
                    }
                }
                Err(error) => {
                    let _ = ready.send(Err(error));
                }
            })
            .map_err(|error| error.to_string())?;
        loaded.recv().map_err(|error| error.to_string())??;
        Ok(Self {
            jobs: Mutex::new(jobs),
        })
    }

    /// The samples for `text` in `voice`, at 24 kHz.
    pub fn create(&self, text: &str, voice: &str) -> Result<Vec<f32>, String> {
        let (reply, result) = mpsc::channel();
        self.jobs
            .lock()
            .map_err(|_| "synthesis_failed".to_string())?
            .send(Job {
                text: text.to_string(),
                voice: voice.to_string(),
                reply,
            })
            .map_err(|_| "synthesis_failed".to_string())?;
        result.recv().map_err(|_| "synthesis_failed".to_string())?
    }
}

struct Engine {
    // The environment must outlive the session made from it.
    _environment: ort::environment::Environment,
    session: Session,
    g2p: loqui_g2p::G2p,
    vocab: HashMap<char, i64>,
    voices_path: PathBuf,
    styles: HashMap<String, Vec<f32>>,
}

impl Engine {
    fn load(model: &Path, voices_path: PathBuf) -> Result<Self, String> {
        let environment = ort::init().build().map_err(|error| error.to_string())?;
        let session = Session::builder(&environment)
            .and_then(|mut builder| builder.commit_from_file(model))
            .map_err(|error| error.to_string())?;
        let g2p = loqui_g2p::G2p::new(loqui_g2p::Dialect::American, loqui_g2p::OovFallback::Neural)
            .map_err(|error| error.to_string())?;
        Ok(Self {
            _environment: environment,
            session,
            g2p,
            vocab: vocab::VOCAB.iter().copied().collect(),
            voices_path,
            styles: HashMap::new(),
        })
    }

    fn create(&mut self, text: &str, voice: &str) -> Result<Vec<f32>, String> {
        if !self.styles.contains_key(voice) {
            let styles =
                voices::load(&self.voices_path, voice).map_err(|error| error.to_string())?;
            self.styles.insert(voice.to_string(), styles);
        }
        // What the model can be fed: anything outside its vocabulary is dropped.
        let phonemes: String = self
            .g2p
            .phonemize(text)
            .chars()
            .filter(|symbol| self.vocab.contains_key(symbol))
            .collect();
        let mut audio = Vec::new();
        for batch in split_phonemes(phonemes.trim()) {
            let tokens: Vec<i64> = batch
                .chars()
                .take(MAX_PHONEMES)
                .map(|symbol| self.vocab[&symbol])
                .collect();
            let styles = &self.styles[voice];
            let samples = synthesize(&mut self.session, styles, &tokens)
                .map_err(|error| error.to_string())?;
            audio.extend_from_slice(trim::trim(&samples));
        }
        Ok(audio)
    }
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
/// style vector for that many tokens, and speed 1.0 as `tts_worker.py` uses
/// (the playback rate is applied by the player's time-pitch instead).
fn synthesize(
    session: &mut Session,
    styles: &[f32],
    tokens: &[i64],
) -> Result<Vec<f32>, ort::Error> {
    let rows = styles.len() / voices::STYLE_SIZE;
    let row = tokens.len().min(rows.saturating_sub(1)) * voices::STYLE_SIZE;
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

    #[test]
    fn models_are_looked_for_beside_voice_models_dir_first() {
        // SAFETY: tests that read these variables run in this one test.
        let dirs = model_dirs();
        assert_eq!(dirs.last(), Some(&download_dir()));
        assert!(download_dir().ends_with(".local/share/kokoro"));
    }
}
