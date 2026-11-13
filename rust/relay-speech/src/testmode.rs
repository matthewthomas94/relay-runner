//! `RELAY_SPEECH_TEST_MODE=1`: silence of a fixed length per character instead
//! of Kokoro, and a timed null output instead of an audio device. Everything
//! else runs as in a session. See "Test mode" in
//! docs/specs/speech-service-protocol.md.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::player::{BUFFER_SECONDS, Feed, Output, PcmFormat, PlaybackError};
use crate::support::{self, Json, JsonLog, number};
use crate::synth::{Audio, Synthesizer};

pub const SAMPLE_RATE: u32 = 24_000;

/// What would have reached the speaker, one JSON object per line.
pub struct PlaybackLog(JsonLog);

impl PlaybackLog {
    pub fn new(path: Option<PathBuf>) -> Self {
        Self(JsonLog::new(path))
    }

    pub fn write(&self, event: &str, fields: &[(&str, Value)]) {
        if !self.0.enabled() {
            return;
        }
        let mut record = Json::new();
        record.insert("event".into(), event.into());
        record.insert("at".into(), number(support::now()));
        for (key, value) in fields {
            record.insert((*key).to_string(), value.clone());
        }
        self.0.write(&record);
    }
}

pub struct SilenceSynth {
    log: Arc<PlaybackLog>,
    ms_per_char: f64,
}

impl SilenceSynth {
    pub fn new(log: Arc<PlaybackLog>, ms_per_char: f64) -> Self {
        Self { log, ms_per_char }
    }
}

impl Synthesizer for SilenceSynth {
    fn loaded(&self) -> bool {
        true
    }

    fn render(&self, text: &str, voice: &str) -> Result<Option<Audio>, String> {
        let seconds = BUFFER_SECONDS.max(text.chars().count() as f64 * self.ms_per_char / 1000.0);
        let samples = (seconds * f64::from(SAMPLE_RATE)).round() as usize;
        self.log.write(
            "synthesized",
            &[
                ("text", text.into()),
                ("seconds", number(seconds)),
                ("voice", voice.into()),
            ],
        );
        Ok(Some(Audio {
            samples: vec![0; samples],
            sample_rate: SAMPLE_RATE,
        }))
    }
}

/// Consumes the speech stream in real time, `rate` times faster, without a device.
pub struct NullOutput {
    format: PcmFormat,
    rate: f64,
    feed: Arc<Feed>,
    log: Arc<PlaybackLog>,
    stopped: Arc<AtomicBool>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl NullOutput {
    pub fn create(
        format: PcmFormat,
        rate: f64,
        feed: Arc<Feed>,
        log: Arc<PlaybackLog>,
    ) -> Arc<dyn Output> {
        Arc::new(Self {
            format,
            rate,
            feed,
            log,
            stopped: Arc::new(AtomicBool::new(false)),
            thread: Mutex::new(None),
        })
    }
}

impl Output for NullOutput {
    fn start(&self) -> Result<(), PlaybackError> {
        self.log.write(
            "output_started",
            &[
                ("sample_rate", self.format.sample_rate.into()),
                ("rate", number(self.rate)),
            ],
        );
        let (feed, stopped) = (self.feed.clone(), self.stopped.clone());
        let mut buffer = vec![0i16; self.format.buffer_samples()];
        let interval = Duration::from_secs_f64(BUFFER_SECONDS / self.rate);
        let handle = std::thread::Builder::new()
            .name("speech-null-output".into())
            .spawn(move || {
                let mut deadline = Instant::now();
                while !stopped.load(Ordering::Acquire) {
                    feed.render(&mut buffer);
                    deadline += interval;
                    let now = Instant::now();
                    if deadline > now {
                        std::thread::sleep(deadline - now);
                    }
                }
            })
            .map_err(|_| PlaybackError("playback_failed"))?;
        *self.thread.lock().unwrap() = Some(handle);
        Ok(())
    }

    fn fade_out(&self, _seconds: f64) {}

    fn wait_faded(&self, _timeout: f64) -> bool {
        true
    }

    fn dispose(&self) {
        if self.stopped.swap(true, Ordering::AcqRel) {
            return;
        }
        if let Some(handle) = self.thread.lock().unwrap().take()
            && handle.thread().id() != std::thread::current().id()
        {
            let _ = handle.join();
        }
        self.log.write("output_stopped", &[]);
    }

    fn error(&self) -> Option<String> {
        None
    }
}
