//! The speech worker, the twin of `TTSWorker` in `services/tts_worker.py`: it
//! holds the reply waiting to be played, chimes and publishes the waiting
//! preview, renders the first sentence speculatively while the reply waits,
//! renders each next sentence while the current one plays, and hands the audio
//! to the persistent player under the audio lease.
//!
//! `state` is the worker's play lock. The coordinator's callbacks are made
//! while it is held, never the other way round.

use std::collections::{HashMap, VecDeque};
use std::os::unix::net::UnixDatagram;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, mpsc};
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::config::{self, TtsConfig};
use crate::coordinator::{AudioPart, RemoteJob, SpeechHooks, WorkItem, Worker};
use crate::intent::SpeechIntent;
use crate::player::{OutputFactory, PcmFormat, SpeechPlayer};
use crate::remote_audio;
use crate::sentences::{is_py_space, sentence_chunks};
use crate::support::{self, AudioLease, Json, LeaseError, StateSocket, number, opt_int, opt_text};
use crate::synth::{Audio, Synthesizer};
use crate::testmode::PlaybackLog;

/// How long a sentence may take to render before the reply fails.
const SYNTHESIS_TIMEOUT: Duration = Duration::from_secs(30);
const LEASE_TIMEOUT: Duration = Duration::from_secs(2);
const PREVIEW_CHARS: usize = 2000;

#[derive(Clone, Debug, PartialEq)]
struct Selection {
    voice: String,
    rate: f64,
    epoch: u64,
}

struct State {
    pending_text: String,
    pending_display_text: String,
    pending_intent: Option<Arc<SpeechIntent>>,
    current_intent: Option<Arc<SpeechIntent>>,
    current_spoken_text: String,
    current_display_text: String,
    paused: bool,
    last_unheard_text: String,
    last_unheard_display_text: String,
    last_response_text: String,
    last_response_display_text: String,
    /// The last audio played and its rate, for the tutorial's replay.
    last_audio: Option<(Arc<Audio>, f64)>,
    chime: Option<Child>,
    config: TtsConfig,
    selection_epoch: u64,
    configured_selection: Selection,
    render_selections: HashMap<u64, Selection>,
}

impl State {
    fn selection(&self) -> Selection {
        Selection {
            voice: self.config.voice.clone(),
            rate: self.config.rate,
            epoch: self.selection_epoch,
        }
    }
}

/// Speculative TTS: the first sentence of the waiting reply, rendered while
/// the pill shows, so audio is ready when the user plays it.
#[derive(Default)]
struct Speculation {
    text: String,
    audio: Option<Arc<Audio>>,
    ready_at: Option<f64>,
    done: bool,
    selection: Option<Selection>,
    token: u64,
}

pub struct Options {
    pub synth: Arc<dyn Synthesizer>,
    /// Builds the player's output; told whether a reply is still in progress.
    pub output_factory: Box<dyn FnOnce(Arc<AtomicBool>) -> OutputFactory>,
    pub config_path: PathBuf,
    /// `RELAY_TUTORIAL_TTS=1`: the onboarding voice, never auto-playing.
    pub tutorial: bool,
    /// The tutorial binds the play control socket itself; a session's
    /// coordinator owns it otherwise.
    pub control_socket: Option<PathBuf>,
    pub test_log: Option<Arc<PlaybackLog>>,
}

pub struct TtsWorker {
    synth: Arc<dyn Synthesizer>,
    player: SpeechPlayer,
    config_path: PathBuf,
    tutorial: bool,
    test_log: Option<Arc<PlaybackLog>>,
    overlay: StateSocket,
    hooks: OnceLock<Arc<dyn SpeechHooks>>,
    queue: Mutex<VecDeque<WorkItem>>,
    queue_ready: Condvar,
    state: Mutex<State>,
    generation: Arc<AtomicU64>,
    playing: Arc<AtomicBool>,
    spec: Mutex<Speculation>,
    spec_ready: Condvar,
    remote_jobs: Mutex<mpsc::Sender<RemoteJob>>,
    remote_encoding_failed: AtomicBool,
    shutdown: AtomicBool,
}

impl TtsWorker {
    pub fn new(options: Options) -> Arc<Self> {
        let mut config = config::load(&options.config_path);
        if options.tutorial {
            config.auto_play = false;
        }
        let playing = Arc::new(AtomicBool::new(false));
        let keep_alive = playing.clone();
        let player = SpeechPlayer::new(
            (options.output_factory)(playing.clone()),
            Box::new(move || keep_alive.load(Ordering::Acquire)),
        );
        let (remote_jobs, remote_queue) = mpsc::channel();
        let selection = Selection {
            voice: config.voice.clone(),
            rate: config.rate,
            epoch: 0,
        };
        let worker = Arc::new(Self {
            synth: options.synth,
            player,
            config_path: options.config_path,
            tutorial: options.tutorial,
            test_log: options.test_log,
            overlay: StateSocket::from_environment(options.tutorial),
            hooks: OnceLock::new(),
            queue: Mutex::new(VecDeque::new()),
            queue_ready: Condvar::new(),
            state: Mutex::new(State {
                pending_text: String::new(),
                pending_display_text: String::new(),
                pending_intent: None,
                current_intent: None,
                current_spoken_text: String::new(),
                current_display_text: String::new(),
                paused: false,
                last_unheard_text: String::new(),
                last_unheard_display_text: String::new(),
                last_response_text: String::new(),
                last_response_display_text: String::new(),
                last_audio: None,
                chime: None,
                config,
                selection_epoch: 0,
                configured_selection: selection,
                render_selections: HashMap::new(),
            }),
            generation: Arc::new(AtomicU64::new(0)),
            playing,
            spec: Mutex::new(Speculation::default()),
            spec_ready: Condvar::new(),
            remote_jobs: Mutex::new(remote_jobs),
            remote_encoding_failed: AtomicBool::new(!remote_audio::encoder_available()),
            shutdown: AtomicBool::new(false),
        });
        let collector = worker.clone();
        std::thread::Builder::new()
            .name("speech-collector".into())
            .spawn(move || collector.collect_loop())
            .expect("collector thread");
        let remote = worker.clone();
        std::thread::Builder::new()
            .name("speech-remote".into())
            .spawn(move || {
                for job in remote_queue {
                    if remote.shutdown.load(Ordering::Acquire) {
                        break;
                    }
                    remote.voice_remote(job);
                }
            })
            .expect("remote speech thread");
        if let Some(path) = options.control_socket {
            let control = worker.clone();
            std::thread::Builder::new()
                .name("speech-worker-control".into())
                .spawn(move || control.control_loop(path))
                .expect("control thread");
        }
        worker
    }

    pub fn voice(&self) -> String {
        self.lock().config.voice.clone()
    }

    pub fn rate(&self) -> f64 {
        self.lock().config.rate
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn is_current(&self, generation: u64) -> bool {
        self.generation.load(Ordering::Acquire) == generation
            && self.playing.load(Ordering::Acquire)
    }

    fn current_check(&self, generation: u64) -> Arc<dyn Fn() -> bool + Send + Sync> {
        let (current, playing) = (self.generation.clone(), self.playing.clone());
        Arc::new(move || {
            current.load(Ordering::Acquire) == generation && playing.load(Ordering::Acquire)
        })
    }

    fn eligible(&self, intent: Option<&Arc<SpeechIntent>>) -> bool {
        match (intent, self.hooks.get()) {
            (Some(intent), Some(hooks)) => hooks.eligible(intent),
            _ => true,
        }
    }

    fn observe(&self, state: &str, intent: Option<&Arc<SpeechIntent>>, at: Option<f64>) {
        if let (Some(intent), Some(hooks)) = (intent, self.hooks.get()) {
            hooks.observe(state, intent, at);
        }
    }

    fn notify(
        &self,
        state: &str,
        text: Option<&str>,
        intent: Option<&SpeechIntent>,
        stop_reason: Option<&str>,
    ) {
        let mut fields = presentation_fields(intent, stop_reason);
        if let Some(text) = text {
            fields.insert(
                "text".into(),
                text.chars().take(PREVIEW_CHARS).collect::<String>().into(),
            );
        }
        self.overlay.notify(state, fields);
    }

    fn log(&self, event: &str, fields: &[(&str, Value)]) {
        if let Some(log) = &self.test_log {
            log.write(event, fields);
        }
    }

    // -- Collection ------------------------------------------------------------

    /// Continuously drain the input queue. Auto-plays or queues based on config.
    fn collect_loop(self: Arc<Self>) {
        let mut idle_ticks = 0;
        while !self.shutdown.load(Ordering::Acquire) {
            let available = {
                let queue = self.queue.lock().unwrap();
                let (queue, _) = self
                    .queue_ready
                    .wait_timeout_while(queue, Duration::from_millis(200), |queue| queue.is_empty())
                    .unwrap();
                !queue.is_empty()
            };
            if !available {
                idle_ticks += 1;
                let (auto_play, has_text) = {
                    let st = self.lock();
                    (st.config.auto_play, !st.pending_text.trim().is_empty())
                };
                if auto_play && has_text && idle_ticks >= 5 && !self.playing.load(Ordering::Acquire)
                {
                    self.play();
                }
                continue;
            }
            idle_ticks = 0;
            // Take the item under the play lock, so a play request always finds
            // a reply that is on its way to being pending.
            let item = {
                let mut st = self.lock();
                let Some(item) = self.queue.lock().unwrap().pop_front() else {
                    continue;
                };
                if item.control.is_none() {
                    self.handle_chunk_locked(&mut st, item.clone());
                }
                item
            };
            if let Some(control) = &item.control {
                self.handle_command(control);
            } else if item.intent.is_some()
                && self.lock().config.auto_play
                && !self.playing.load(Ordering::Acquire)
            {
                // Coordinated intents are complete, command-scoped responses;
                // they do not need the legacy coalescing delay.
                self.play();
            }
        }
    }

    /// Serialize collection through waiting-pill publication with play(): once
    /// the pill is visible, play can always claim this exact pending response.
    fn handle_chunk_locked(&self, st: &mut State, item: WorkItem) {
        let text = item.text.trim_matches(is_py_space).to_string();
        let display = item.display_text.trim_matches(is_py_space).to_string();
        let intent = item.intent;
        if text.is_empty() {
            return;
        }
        if !self.eligible(intent.as_ref()) {
            // The coordinator may already have published this preview. Clear
            // only its identity before cancellation advances the queue.
            self.notify("idle", None, intent.as_deref(), None);
            self.observe("cancelled", intent.as_ref(), None);
            return;
        }
        let was_empty = st.pending_text.trim().is_empty();
        let mut replaced = None;
        if intent.is_some() {
            replaced = st.pending_intent.take();
            st.pending_text = text;
            st.pending_display_text = display.clone();
            st.pending_intent = intent.clone();
        } else if !st.pending_text.is_empty() {
            st.pending_text = format!("{} {text}", st.pending_text);
        } else {
            st.pending_text = text;
        }
        if !display.is_empty() {
            st.pending_display_text = display;
        } else if was_empty {
            st.pending_display_text.clear();
        }
        let full_text = st.pending_text.trim().to_string();
        if !full_text.is_empty() {
            st.last_response_text = full_text.clone();
        }
        let preview = Some(st.pending_display_text.trim().to_string())
            .filter(|preview| !preview.is_empty())
            .unwrap_or_else(|| full_text.clone());
        if !preview.is_empty() {
            st.last_response_display_text = preview.clone();
        }
        let is_playing = self.playing.load(Ordering::Acquire);
        if let Some(replaced) = replaced
            && intent
                .as_ref()
                .is_none_or(|intent| intent.utterance_id != replaced.utterance_id)
        {
            self.observe("cancelled", Some(&replaced), None);
        }
        if full_text.is_empty() {
            return;
        }
        self.observe("queued", intent.as_ref(), None);
        if was_empty && !st.config.auto_play {
            self.play_chime(st);
        }
        // An explicit replay starts straight away; skip the waiting preview so
        // the notch does not flash "Replay available".
        if intent
            .as_ref()
            .is_none_or(|intent| intent.replay_of.is_none())
            && !preview.is_empty()
        {
            self.notify("message_waiting", Some(&preview), intent.as_deref(), None);
        }
        if !is_playing {
            self.start_speculation(&full_text, st.selection());
        }
    }

    fn handle_command(&self, command: &str) {
        match command {
            "play" => self.play(),
            "pause" => self.pause(),
            "skip" => self.skip_with("user_stop"),
            "replay" => self.replay_last(),
            "toggle" => {
                let paused = self.lock().paused;
                if self.playing.load(Ordering::Acquire) && !paused {
                    self.pause();
                } else {
                    self.play();
                }
            }
            _ => {}
        }
    }

    fn control_loop(&self, path: PathBuf) {
        let _ = std::fs::remove_file(&path);
        let socket = match UnixDatagram::bind(&path) {
            Ok(socket) => socket,
            Err(error) => {
                eprintln!("[relay_speech] Control socket unavailable: {error}");
                return;
            }
        };
        let _ = socket.set_read_timeout(Some(Duration::from_millis(500)));
        let mut buffer = [0u8; 256];
        while !self.shutdown.load(Ordering::Acquire) {
            if let Ok(size) = socket.recv(&mut buffer) {
                let command = String::from_utf8_lossy(&buffer[..size])
                    .trim()
                    .to_lowercase();
                self.handle_command(&command);
            }
        }
        let _ = std::fs::remove_file(&path);
    }

    // -- Playback ----------------------------------------------------------------

    fn play_now(&self) {
        let mut st = self.lock();
        if self.playing.load(Ordering::Acquire) {
            return;
        }
        while st.pending_text.trim().is_empty() {
            let Some(item) = self.queue.lock().unwrap().pop_front() else {
                break;
            };
            // As in Python, play() takes queued text only; a queued control is dropped.
            self.handle_chunk_locked(&mut st, item);
        }
        let text = st.pending_text.trim().to_string();
        let display = Some(st.pending_display_text.trim().to_string())
            .filter(|display| !display.is_empty())
            .unwrap_or_else(|| text.clone());
        let intent = st.pending_intent.take();
        st.pending_text.clear();
        st.pending_display_text.clear();
        if text.is_empty() {
            return;
        }
        st.last_unheard_text.clear();
        st.last_unheard_display_text.clear();
        if !self.eligible(intent.as_ref()) {
            // Option has optimistically moved this preview to preparing.
            self.notify("idle", None, intent.as_deref(), None);
            self.observe("cancelled", intent.as_ref(), None);
            return;
        }
        self.play_text_locked(&mut st, &text, &display, intent);
    }

    fn play_text_locked(
        &self,
        st: &mut State,
        text: &str,
        display: &str,
        intent: Option<Arc<SpeechIntent>>,
    ) {
        let chunks = sentence_chunks(text);
        if chunks.is_empty() {
            return;
        }
        let preview = if display.trim().is_empty() {
            text.to_string()
        } else {
            display.trim().to_string()
        };
        st.last_response_text = text.to_string();
        st.last_response_display_text = preview.clone();
        st.current_spoken_text = text.to_string();
        st.current_display_text = preview.clone();
        let generation = self.begin_playback_locked(st);
        let selection = st.selection();
        st.render_selections.insert(generation, selection.clone());
        st.current_intent = intent.clone();
        self.notify("preparing", Some(&preview), intent.as_deref(), None);
        self.observe("preparing", intent.as_ref(), None);
        let Some(worker) = self.me() else { return };
        std::thread::Builder::new()
            .name("speech-reply".into())
            .spawn(move || worker.speak_chunks(chunks, generation, selection, intent))
            .expect("reply thread");
    }

    fn me(&self) -> Option<Arc<Self>> {
        ME.get().and_then(|me| me.upgrade())
    }

    fn begin_playback_locked(&self, st: &mut State) -> u64 {
        stop_chime(st);
        let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        self.playing.store(true, Ordering::Release);
        st.paused = false;
        generation
    }

    fn pause(&self) {
        let mut st = self.lock();
        self.stop_playback_locked(&mut st, "pause");
        st.paused = true;
    }

    /// Stop current audio playback without clearing pending text.
    fn stop_playback_locked(&self, st: &mut State, reason: &str) {
        self.generation.fetch_add(1, Ordering::AcqRel);
        // Fades the output to silence, then stops it.
        self.player.stop();
        stop_chime(st);
        self.playing.store(false, Ordering::Release);
        st.paused = false;
        let intent = st.current_intent.take();
        let current_text = std::mem::take(&mut st.current_spoken_text);
        let current_display = std::mem::take(&mut st.current_display_text);
        if !current_text.is_empty() {
            st.last_response_display_text = if current_display.is_empty() {
                current_text.clone()
            } else {
                current_display
            };
            st.last_response_text = current_text;
        }
        if let Some(intent) = &intent {
            self.notify("idle", None, Some(intent), Some(reason));
        }
        self.observe("cancelled", intent.as_ref(), None);
    }

    /// Stop playback and discard pending text.
    fn skip_with(&self, reason: &str) {
        let mut st = self.lock();
        self.stop_playback_locked(&mut st, reason);
        let text = std::mem::take(&mut st.pending_text).trim().to_string();
        let display = std::mem::take(&mut st.pending_display_text)
            .trim()
            .to_string();
        let pending = st.pending_intent.take();
        if !text.is_empty() {
            st.last_unheard_display_text = if display.is_empty() {
                text.clone()
            } else {
                display
            };
            st.last_unheard_text = text;
        }
        self.observe("cancelled", pending.as_ref(), None);
        self.cancel_speculation();
        self.notify("idle", None, None, None);
    }

    /// The tutorial's replay: the waiting or skipped text, else the last audio.
    fn replay_last(&self) {
        let mut st = self.lock();
        if self.playing.load(Ordering::Acquire) {
            return;
        }
        let mut text = std::mem::take(&mut st.pending_text).trim().to_string();
        let mut display = std::mem::take(&mut st.pending_display_text)
            .trim()
            .to_string();
        if !text.is_empty() {
            st.last_unheard_text.clear();
            st.last_unheard_display_text.clear();
        } else if !st.last_unheard_text.is_empty() {
            text = std::mem::take(&mut st.last_unheard_text);
            display = std::mem::take(&mut st.last_unheard_display_text)
                .trim()
                .to_string();
        }
        if !text.is_empty() {
            let display = if display.is_empty() {
                text.clone()
            } else {
                display
            };
            self.play_text_locked(&mut st, &text, &display, None);
            return;
        }
        let Some((audio, rate)) = st.last_audio.clone() else {
            eprintln!("[relay_speech] Nothing to replay");
            return;
        };
        let preview = if st.last_response_display_text.is_empty() {
            st.last_response_text.clone()
        } else {
            st.last_response_display_text.clone()
        };
        if !preview.is_empty() {
            st.current_spoken_text = st.last_response_text.clone();
            st.current_display_text = preview.clone();
            self.notify("preparing", Some(&preview), None, None);
        }
        let generation = self.begin_playback_locked(&mut st);
        drop(st);
        let Some(worker) = self.me() else { return };
        std::thread::spawn(move || {
            if let Err(error) = worker.play_audio_blocking(&audio, generation, rate, "") {
                eprintln!("[relay_speech] Replay error: {error}");
            }
            let mut st = worker.lock();
            if worker.is_current(generation) {
                worker.playing.store(false, Ordering::Release);
                st.paused = false;
                worker.notify("idle", None, None, None);
                st.current_spoken_text.clear();
                st.current_display_text.clear();
            }
        });
    }

    /// Synthesize sentence chunks and play them in order.
    fn speak_chunks(
        self: Arc<Self>,
        chunks: Vec<String>,
        generation: u64,
        selection: Selection,
        intent: Option<Arc<SpeechIntent>>,
    ) {
        if !self.synth.loaded() {
            eprintln!("[relay_speech] Kokoro not loaded, skipping a reply");
            self.finish_playback(generation, intent.as_ref(), false, true);
            return;
        }
        let mut played: Vec<Arc<Audio>> = Vec::new();
        let mut failed = false;
        let outcome = (|| -> Result<(), &'static str> {
            {
                let spec = self.spec.lock().unwrap();
                let stale = spec
                    .selection
                    .as_ref()
                    .is_some_and(|spec| *spec != selection);
                drop(spec);
                if stale {
                    self.cancel_speculation();
                }
            }
            let (mut current, mut ready_at) = self.claim_speculation(&chunks[0], SYNTHESIS_TIMEOUT);
            if current.is_none() {
                current = self.synthesize_chunk(&chunks[0], generation, &selection);
                ready_at = current.as_ref().map(|_| support::now());
            }
            if current.is_some() {
                self.observe("wav_ready", intent.as_ref(), ready_at);
            }
            for (index, sentence) in chunks.iter().enumerate() {
                let Some(audio) = current.take() else { break };
                if !self.is_current(generation) || !self.eligible(intent.as_ref()) {
                    break;
                }
                played.push(audio.clone());
                self.set_last_audio(audio.clone(), selection.rate, generation);
                let next = chunks.get(index + 1).map(|text| {
                    let (send, receive) = mpsc::channel();
                    let (worker, text, selection) = (self.clone(), text.clone(), selection.clone());
                    std::thread::spawn(move || {
                        let _ = send.send(worker.synthesize_chunk(&text, generation, &selection));
                    });
                    receive
                });
                if index == 0 {
                    self.observe("started", intent.as_ref(), None);
                }
                self.play_audio_blocking(&audio, generation, selection.rate, sentence)?;
                if !self.is_current(generation) {
                    break;
                }
                if let Some(next) = next {
                    let deadline = Instant::now() + SYNTHESIS_TIMEOUT;
                    loop {
                        match next.recv_timeout(Duration::from_millis(50)) {
                            Ok(audio) => {
                                current = audio;
                                break;
                            }
                            Err(mpsc::RecvTimeoutError::Disconnected) => break,
                            Err(mpsc::RecvTimeoutError::Timeout) => {
                                if !self.is_current(generation) {
                                    break;
                                }
                                if Instant::now() >= deadline {
                                    return Err("synthesis_timeout");
                                }
                            }
                        }
                    }
                }
            }
            Ok(())
        })();
        if let Err(error) = outcome {
            eprintln!("[relay_speech] TTS error: {error}");
            failed = true;
        }
        let mut completed = !failed && self.is_current(generation) && played.len() == chunks.len();
        if !completed && !failed && self.is_current(generation) && self.eligible(intent.as_ref()) {
            failed = true;
        }
        if completed && played.len() > 1 {
            let combined = Audio {
                samples: played
                    .iter()
                    .flat_map(|audio| audio.samples.iter().copied())
                    .collect(),
                sample_rate: played[0].sample_rate,
            };
            if !self.set_last_audio(Arc::new(combined), selection.rate, generation) {
                completed = false;
            }
        }
        self.finish_playback(generation, intent.as_ref(), completed, failed);
    }

    /// Play one sentence on the persistent player. Returns once the audio has
    /// been handed to the output, so the next sentence queues straight behind
    /// it on the same running device.
    fn play_audio_blocking(
        &self,
        audio: &Audio,
        generation: u64,
        rate: f64,
        sentence: &str,
    ) -> Result<(), &'static str> {
        if !self.is_current(generation) {
            return Ok(());
        }
        let current = self.current_check(generation);
        let _lease = match AudioLease::acquire(&|| !current(), LEASE_TIMEOUT) {
            Ok(lease) => lease,
            // A stop while the lease was being taken is a stop, not a failure.
            Err(LeaseError::Cancelled) => return Ok(()),
            Err(_) => return Err("playback_failed"),
        };
        let (chunk, utterance_id) = {
            // Re-check under the same lock as stop: cancelled work cannot start audio.
            let st = self.lock();
            if !self.is_current(generation) {
                return Ok(());
            }
            let intent = st.current_intent.clone();
            let preview = st.current_display_text.trim().to_string();
            let chunk = self
                .player
                .submit(
                    audio.samples.clone().into_boxed_slice(),
                    PcmFormat::mono(audio.sample_rate),
                    rate,
                )
                .map_err(|_| "playback_failed")?;
            let utterance_id = opt_text(intent.as_ref().map(|intent| intent.utterance_id.as_str()));
            self.log(
                "chunk_started",
                &[
                    ("rate", number(rate)),
                    ("utterance_id", utterance_id.clone()),
                    ("text", sentence.into()),
                    ("seconds", number(audio.seconds())),
                ],
            );
            self.notify(
                "speaking",
                (!preview.is_empty()).then_some(preview.as_str()),
                intent.as_deref(),
                None,
            );
            // The event keeps its afplay-era name; latency reports and
            // harnesses key on it. It marks each chunk's hand-off to the player.
            self.observe("afplay_started", intent.as_ref(), None);
            (chunk, utterance_id)
        };
        let result = self.player.wait(&chunk, &|| !current());
        self.log(
            "chunk_finished",
            &[
                ("utterance_id", utterance_id),
                ("text", sentence.into()),
                ("completed", (result == Ok(true)).into()),
            ],
        );
        match result {
            Err(_) if self.is_current(generation) => Err("playback_failed"),
            _ => Ok(()),
        }
    }

    fn finish_playback(
        &self,
        generation: u64,
        intent: Option<&Arc<SpeechIntent>>,
        completed: bool,
        failed: bool,
    ) {
        let mut st = self.lock();
        st.render_selections.remove(&generation);
        let current_text = st.current_spoken_text.clone();
        let current_display = if st.current_display_text.is_empty() {
            current_text.clone()
        } else {
            st.current_display_text.clone()
        };
        let still_current = self.generation.load(Ordering::Acquire) == generation;
        if still_current {
            self.playing.store(false, Ordering::Release);
            st.paused = false;
        }
        // A stop already told the overlay about a coordinated reply, with its
        // stop reason; only the attempt that ended on its own reports here.
        if still_current || (!self.playing.load(Ordering::Acquire) && intent.is_none()) {
            if failed {
                let preview = [
                    &current_display,
                    &st.last_response_display_text,
                    &st.last_response_text,
                ]
                .into_iter()
                .find(|text| !text.is_empty())
                .cloned()
                .unwrap_or_default();
                self.notify("failed", Some(&preview), intent.map(Arc::as_ref), None);
            } else {
                self.notify("idle", None, intent.map(Arc::as_ref), None);
            }
        }
        let intent_was_current = match (&st.current_intent, intent) {
            (Some(current), Some(intent)) => current.utterance_id == intent.utterance_id,
            (None, None) => still_current,
            _ => false,
        };
        if intent_was_current {
            if !current_text.is_empty() {
                st.last_response_text = current_text;
                st.last_response_display_text = current_display;
            }
            st.current_intent = None;
            st.current_spoken_text.clear();
            st.current_display_text.clear();
            let state = if failed {
                "failed"
            } else if completed {
                "completed"
            } else {
                "cancelled"
            };
            self.observe(state, intent, None);
        }
    }

    fn set_last_audio(&self, audio: Arc<Audio>, rate: f64, generation: u64) -> bool {
        let mut st = self.lock();
        if !self.is_current(generation) {
            return false;
        }
        st.last_audio = Some((audio, rate));
        true
    }

    // -- Synthesis -----------------------------------------------------------

    fn synthesize_chunk(
        &self,
        text: &str,
        generation: u64,
        selection: &Selection,
    ) -> Option<Arc<Audio>> {
        let current = self.current_check(generation);
        let audio =
            self.bounded_synthesis(text, &selection.voice, current.clone(), SYNTHESIS_TIMEOUT)?;
        current().then_some(audio)
    }

    /// Synthesis runs on its own thread: a hung render is abandoned when the
    /// reply stops or the deadline passes, and its late audio is dropped.
    fn bounded_synthesis(
        &self,
        text: &str,
        voice: &str,
        current: Arc<dyn Fn() -> bool + Send + Sync>,
        timeout: Duration,
    ) -> Option<Arc<Audio>> {
        let (send, receive) = mpsc::channel();
        let (synth, text, voice, check) = (
            self.synth.clone(),
            text.to_string(),
            voice.to_string(),
            current.clone(),
        );
        std::thread::spawn(move || {
            let audio = if check() {
                synth.render(&text, &voice).ok().flatten()
            } else {
                None
            };
            let _ = send.send(audio);
        });
        let deadline = Instant::now() + timeout;
        loop {
            match receive.recv_timeout(Duration::from_millis(50)) {
                Ok(audio) => return audio.filter(|_| current()).map(Arc::new),
                Err(mpsc::RecvTimeoutError::Disconnected) => return None,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if !current() || Instant::now() >= deadline {
                        return None;
                    }
                }
            }
        }
    }

    /// Begin (or restart) speculative synthesis of the first sentence of
    /// `text`. A newer text supersedes an older one, whose late output is
    /// discarded.
    fn start_speculation(&self, text: &str, selection: Selection) {
        let chunks = sentence_chunks(text);
        if !self.synth.loaded() || chunks.is_empty() {
            return;
        }
        let first = chunks[0].clone();
        let token = {
            let mut spec = self.spec.lock().unwrap();
            if spec.text == first
                && spec.selection.as_ref() == Some(&selection)
                && (spec.audio.is_some() || !spec.done)
            {
                return;
            }
            spec.selection = Some(selection.clone());
            spec.token += 1;
            spec.text = first.clone();
            spec.audio = None;
            spec.ready_at = None;
            spec.done = false;
            self.spec_ready.notify_all();
            spec.token
        };
        let Some(worker) = self.me() else { return };
        std::thread::spawn(move || {
            {
                let spec = worker.spec.lock().unwrap();
                if spec.text != first || spec.token != token {
                    return;
                }
            }
            let audio = match worker.synth.render(&first, &selection.voice) {
                Ok(audio) => audio.map(Arc::new),
                Err(error) => {
                    eprintln!("[relay_speech] Speculation error: {error}");
                    None
                }
            };
            let mut spec = worker.spec.lock().unwrap();
            if spec.text != first || spec.token != token {
                return;
            }
            spec.ready_at = audio.as_ref().map(|_| support::now());
            spec.audio = audio;
            spec.done = true;
            worker.spec_ready.notify_all();
        });
    }

    /// The speculative audio and its ready time, waiting up to `timeout` for a
    /// render in flight. The caller takes it; the slot is cleared.
    fn claim_speculation(
        &self,
        text: &str,
        timeout: Duration,
    ) -> (Option<Arc<Audio>>, Option<f64>) {
        let deadline = Instant::now() + timeout;
        let mut spec = self.spec.lock().unwrap();
        loop {
            if spec.text != text {
                return (None, None);
            }
            if spec.done {
                let claimed = (spec.audio.take(), spec.ready_at.take());
                spec.text.clear();
                spec.done = false;
                self.spec_ready.notify_all();
                return claimed;
            }
            let now = Instant::now();
            if now >= deadline {
                return (None, None);
            }
            spec = self
                .spec_ready
                .wait_timeout(spec, deadline - now)
                .unwrap()
                .0;
        }
    }

    /// Drop any cached or in-flight speculation; a render in flight cannot be
    /// preempted, but its result is discarded.
    fn cancel_speculation(&self) {
        let mut spec = self.spec.lock().unwrap();
        spec.token += 1;
        spec.selection = None;
        spec.text.clear();
        spec.audio = None;
        spec.ready_at = None;
        spec.done = false;
        self.spec_ready.notify_all();
    }

    // -- Relay Remote ----------------------------------------------------------

    /// Voice one reply for a phone: each sentence is synthesised, encoded and
    /// emitted before the next starts. The player and the audio lease are
    /// never touched, so no Mac audio device opens.
    fn voice_remote(&self, job: RemoteJob) {
        let cancelled = || job.cancelled.load(Ordering::SeqCst);
        let voice = self.lock().config.voice.clone();
        let chunks = sentence_chunks(&job.text);
        let mut sent = 0i64;
        let outcome = (|| -> Result<(), &'static str> {
            for (index, text) in chunks.iter().enumerate() {
                if cancelled() {
                    return Ok(());
                }
                let check = job.cancelled.clone();
                let not_cancelled: Arc<dyn Fn() -> bool + Send + Sync> =
                    Arc::new(move || !check.load(Ordering::SeqCst));
                let Some(audio) =
                    self.bounded_synthesis(text, &voice, not_cancelled, SYNTHESIS_TIMEOUT)
                else {
                    if cancelled() {
                        return Ok(());
                    }
                    return Err("synthesis_failed");
                };
                let data = remote_audio::encode(&audio).map_err(|_| {
                    // Later replies go out as text for the phone's own voice.
                    self.remote_encoding_failed.store(true, Ordering::SeqCst);
                    "encoding_failed"
                })?;
                let pieces = remote_audio::split(&data);
                let last_sentence = index == chunks.len() - 1;
                let total = if last_sentence {
                    sent + pieces.len() as i64
                } else {
                    0
                };
                for (offset, piece) in pieces.iter().enumerate() {
                    if cancelled() {
                        return Ok(());
                    }
                    let part = AudioPart {
                        part: sent,
                        parts: total,
                        last: last_sentence && offset == pieces.len() - 1,
                        data: piece.clone(),
                    };
                    (job.emit)(&part).map_err(|_| "remote_send_failed")?;
                    sent += 1;
                }
            }
            Ok(())
        })();
        if let Err(reason) = outcome {
            // Always end the stream so the phone does not wait for audio that
            // will never come; unexpected errors get a fixed reason.
            if cancelled() {
                return;
            }
            let _ = (job.emit)(&AudioPart {
                part: sent,
                parts: sent + 1,
                last: true,
                data: String::new(),
            });
            let known = matches!(reason, "synthesis_failed" | "encoding_failed");
            (job.failed)(if known { reason } else { "synthesis_failed" });
        }
    }

    // -- Chime ---------------------------------------------------------------

    fn play_chime(&self, st: &mut State) {
        if self.test_log.is_some() {
            self.log("chime", &[]);
            return;
        }
        if !st.config.chime.exists() {
            return;
        }
        stop_chime(st);
        st.chime = Command::new("afplay")
            .arg(&st.config.chime)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .ok();
    }
}

static ME: OnceLock<std::sync::Weak<TtsWorker>> = OnceLock::new();

impl TtsWorker {
    /// The one worker of this process, for the threads it starts.
    pub fn install(worker: &Arc<Self>) {
        let _ = ME.set(Arc::downgrade(worker));
    }
}

fn stop_chime(st: &mut State) {
    if let Some(mut chime) = st.chime.take()
        && chime.try_wait().ok().flatten().is_none()
    {
        let _ = chime.kill();
        let _ = chime.wait();
    }
}

/// `_presentation_fields`: the identity of an utterance on a state datagram.
fn presentation_fields(intent: Option<&SpeechIntent>, stop_reason: Option<&str>) -> Json {
    let mut fields = Json::new();
    let Some(intent) = intent else { return fields };
    let utterance_id = intent.utterance_id.trim();
    let original = if intent.original_utterance_id.trim().is_empty() {
        utterance_id
    } else {
        intent.original_utterance_id.trim()
    };
    let replay_of = intent
        .replay_of
        .as_deref()
        .map(str::trim)
        .filter(|id| !id.is_empty());
    fields.insert(
        "utterance_id".into(),
        opt_text(Some(utterance_id).filter(|id| !id.is_empty())),
    );
    fields.insert(
        "original_utterance_id".into(),
        opt_text(Some(original).filter(|id| !id.is_empty())),
    );
    fields.insert("replay_of".into(), opt_text(replay_of));
    fields.insert(
        "presentation_mode".into(),
        if replay_of.is_some() {
            "explicit_replay"
        } else {
            "new_delivery"
        }
        .into(),
    );
    fields.insert("stop_reason".into(), opt_text(stop_reason));
    fields.insert("relay_command_seq".into(), opt_int(intent.command_seq));
    fields.insert(
        "relay_command_id".into(),
        opt_text(intent.command_id.as_deref()),
    );
    if !intent.session_key.trim().is_empty() {
        fields.insert("session_key".into(), intent.session_key.trim().into());
    }
    fields
}

impl Worker for TtsWorker {
    fn set_hooks(&self, hooks: Arc<dyn SpeechHooks>) {
        let _ = self.hooks.set(hooks);
    }

    fn enqueue(&self, item: WorkItem) {
        self.queue.lock().unwrap().push_back(item);
        self.queue_ready.notify_all();
    }

    fn play(&self) {
        self.play_now();
    }

    fn skip(&self) {
        self.skip_with("user_stop");
    }

    fn stop_playback(&self, reason: &str) {
        let mut st = self.lock();
        self.stop_playback_locked(&mut st, reason);
    }

    /// Re-read config.toml; a changed voice or rate stops the current playback.
    fn reload_config(&self) {
        let mut config = config::load(&self.config_path);
        if self.tutorial {
            config.auto_play = false;
        }
        let mut st = self.lock();
        let previous = st.configured_selection.clone();
        st.config = config;
        if previous != st.selection() {
            st.selection_epoch += 1;
            self.cancel_speculation();
            self.stop_playback_locked(&mut st, "voice_changed");
        }
        st.configured_selection = st.selection();
        eprintln!(
            "[relay_speech] Config reloaded: voice={}, rate={}",
            st.config.voice, st.config.rate
        );
    }

    fn shutdown(&self) {
        self.shutdown.store(true, Ordering::Release);
        self.skip_with("user_stop");
        self.player.close();
        self.lock().last_audio = None;
        // Wake the remote thread so it sees the flag.
        drop(self.remote_jobs.lock().map(|jobs| jobs.clone()));
    }

    fn remote_audio_available(&self) -> bool {
        self.synth.loaded() && !self.remote_encoding_failed.load(Ordering::SeqCst)
    }

    fn synthesize_remote(&self, job: RemoteJob) {
        if let Ok(jobs) = self.remote_jobs.lock() {
            let _ = jobs.send(job);
        }
    }
}

/// The tutorial voice's standalone mode: lines from stdin are queued, and
/// `__PLAY__`, `__REPLAY__` and `__CANCEL__` act on them.
pub fn queue_tutorial_line(worker: &TtsWorker, line: &str) {
    let control = match line {
        "__PLAY__" => Some("play"),
        "__REPLAY__" => Some("replay"),
        "__CANCEL__" => Some("skip"),
        "" => return,
        _ => None,
    };
    worker.enqueue(WorkItem {
        text: if control.is_some() {
            String::new()
        } else {
            line.to_string()
        },
        display_text: String::new(),
        intent: None,
        control: control.map(str::to_string),
    });
}
