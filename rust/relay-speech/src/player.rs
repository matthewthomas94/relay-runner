//! Persistent speech output, the twin of `services/speech_player.py` (RR-438).
//!
//! One output queue runs for a reply: sentence chunks are appended to one PCM
//! stream, so boundaries are gapless and the device starts at most once per
//! reply, which is what keeps CoreAudio from clicking on every sentence. A stop
//! ramps the output volume to zero over `FADE_SECONDS` before the queue stops,
//! and after `IDLE_STOP_SECONDS` of silence the queue stops on its own.
//!
//! The refill callback reads the stream without allocating or locking: chunks
//! sit in a fixed ring of pointers that the producer fills and only the
//! consumer advances, and every chunk's progress is an atomic. The producer
//! frees a chunk only after the consumer has moved past it.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU8, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::support::{self, monotonic_nanos};

pub const FADE_SECONDS: f64 = 0.02;
/// Stop the queue only after the ramp has reached the output.
pub const FADE_SETTLE_SECONDS: f64 = 0.015;
/// Upper bound on waiting for the ramp if the output stops calling back.
pub const FADE_WAIT_TIMEOUT: f64 = 0.1;
pub const IDLE_STOP_SECONDS: f64 = 2.0;
/// While the worker is still inside a reply, a slow next-chunk render should
/// not restart the device mid-reply.
pub const IDLE_HOLD_SECONDS: f64 = 15.0;
pub const STALL_SECONDS: f64 = 2.0;
pub const MONITOR_SECONDS: f64 = 0.1;
pub const BUFFER_SECONDS: f64 = 0.02;
pub const BUFFER_COUNT: usize = 4;
pub const MIN_RATE: f64 = 0.5;
pub const MAX_RATE: f64 = 2.0;
/// Sentences queued ahead of the output at most; the worker queues one.
const RING_SLOTS: usize = 64;
/// How often `wait` looks at a chunk. Four 20 ms buffers are queued ahead of
/// the speaker, so a sentence handed off is followed by the next well in time.
const WAIT_POLL: Duration = Duration::from_millis(5);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaybackError(pub &'static str);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PcmFormat {
    pub sample_rate: u32,
    pub channels: u16,
}

impl PcmFormat {
    pub const fn mono(sample_rate: u32) -> Self {
        Self {
            sample_rate,
            channels: 1,
        }
    }
    pub fn frame_bytes(self) -> usize {
        usize::from(self.channels) * 2
    }
    /// Samples in one `BUFFER_SECONDS` buffer, across channels.
    pub fn buffer_samples(self) -> usize {
        ((f64::from(self.sample_rate) * BUFFER_SECONDS).round() as usize).max(1)
            * usize::from(self.channels)
    }
}

const PENDING: u8 = 0;
const DONE: u8 = 1;
const CANCELLED: u8 = 2;
const FAILED: u8 = 3;

/// One submitted sentence; it is done once every sample was handed to the output.
pub struct Chunk {
    pcm: Box<[i16]>,
    position: AtomicUsize,
    state: AtomicU8,
}

impl Chunk {
    fn new(pcm: Box<[i16]>) -> Self {
        let state = if pcm.is_empty() { DONE } else { PENDING };
        Self {
            pcm,
            position: AtomicUsize::new(0),
            state: AtomicU8::new(state),
        }
    }

    fn finish(&self, state: u8) {
        let _ = self
            .state
            .compare_exchange(PENDING, state, Ordering::AcqRel, Ordering::Acquire);
    }

    pub fn is_finished(&self) -> bool {
        self.state.load(Ordering::Acquire) != PENDING
    }
}

/// Ordered chunks rendered as one continuous stream.
pub struct Stream {
    slots: Box<[AtomicPtr<Chunk>]>,
    /// Chunks the consumer has finished with; only `render` advances it.
    head: AtomicUsize,
    /// Chunks published; only the producer advances it, under the player lock.
    tail: AtomicUsize,
    /// Claimed by the one `render` call that may read the ring. A retired
    /// output still fading never races the new one: whichever fails the claim
    /// renders silence, without waiting.
    consumer: AtomicBool,
    last_render_at: AtomicU64,
    last_audio_at: AtomicU64,
}

impl Stream {
    fn new() -> Self {
        let now = monotonic_nanos();
        Self {
            slots: (0..RING_SLOTS)
                .map(|_| AtomicPtr::new(std::ptr::null_mut()))
                .collect(),
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
            consumer: AtomicBool::new(false),
            last_render_at: AtomicU64::new(now),
            last_audio_at: AtomicU64::new(now),
        }
    }

    /// Fill `out` with the next samples of the stream; missing audio is
    /// silence. Called on the output's thread: it neither allocates nor locks.
    pub fn render(&self, out: &mut [i16]) {
        if self
            .consumer
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            out.fill(0);
            return;
        }
        let now = monotonic_nanos();
        self.last_render_at.store(now, Ordering::Release);
        let mut head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Acquire);
        let mut written = 0;
        while written < out.len() && head < tail {
            // SAFETY: slots below `tail` hold chunks the producer keeps alive
            // until `head` has passed them.
            let chunk = unsafe { &*self.slots[head % RING_SLOTS].load(Ordering::Acquire) };
            if chunk.state.load(Ordering::Acquire) != PENDING {
                head += 1;
                continue;
            }
            let position = chunk.position.load(Ordering::Relaxed);
            let take = (out.len() - written).min(chunk.pcm.len() - position);
            out[written..written + take].copy_from_slice(&chunk.pcm[position..position + take]);
            written += take;
            chunk.position.store(position + take, Ordering::Relaxed);
            if position + take >= chunk.pcm.len() {
                chunk.finish(DONE);
                head += 1;
            }
        }
        self.head.store(head, Ordering::Release);
        if written > 0 {
            self.last_audio_at.store(now, Ordering::Release);
        }
        out[written..].fill(0);
        self.consumer.store(false, Ordering::Release);
    }

    fn mark_started(&self) {
        let now = monotonic_nanos();
        self.last_render_at.store(now, Ordering::Release);
        self.last_audio_at.store(now, Ordering::Release);
    }

    fn seconds_since(stamp: &AtomicU64) -> f64 {
        monotonic_nanos().saturating_sub(stamp.load(Ordering::Acquire)) as f64 / 1e9
    }
}

/// Connects one output to the shared stream until that output is retired.
pub struct Feed {
    stream: Arc<Stream>,
    attached: AtomicBool,
}

impl Feed {
    /// A retired output keeps rendering only silence while it fades out.
    pub fn render(&self, out: &mut [i16]) {
        if self.attached.load(Ordering::Acquire) {
            self.stream.render(out);
        } else {
            out.fill(0);
        }
    }
}

/// One output device queue at a fixed format and rate.
pub trait Output: Send + Sync {
    fn start(&self) -> Result<(), PlaybackError>;
    /// Ramp the output volume to zero; it applies to audio already queued.
    fn fade_out(&self, seconds: f64);
    fn wait_faded(&self, timeout: f64) -> bool;
    /// Ends the output and its callbacks; none runs after this returns.
    fn dispose(&self);
    fn error(&self) -> Option<String>;
}

pub type OutputFactory =
    Box<dyn Fn(PcmFormat, f64, Arc<Feed>) -> Result<Arc<dyn Output>, PlaybackError> + Send + Sync>;

struct Current {
    feed: Arc<Feed>,
    output: Option<Arc<dyn Output>>,
    config: (PcmFormat, f64),
}

struct PlayerState {
    closed: bool,
    current: Option<Current>,
    /// Every chunk the ring may still point at, with its ring index.
    owned: VecDeque<(usize, Arc<Chunk>)>,
}

struct Inner {
    stream: Arc<Stream>,
    state: Mutex<PlayerState>,
    factory: OutputFactory,
    keep_alive: Box<dyn Fn() -> bool + Send + Sync>,
}

#[derive(Clone)]
pub struct SpeechPlayer {
    inner: Arc<Inner>,
}

impl SpeechPlayer {
    pub fn new(factory: OutputFactory, keep_alive: Box<dyn Fn() -> bool + Send + Sync>) -> Self {
        Self {
            inner: Arc::new(Inner {
                stream: Arc::new(Stream::new()),
                state: Mutex::new(PlayerState {
                    closed: false,
                    current: None,
                    owned: VecDeque::new(),
                }),
                factory,
                keep_alive,
            }),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, PlayerState> {
        self.inner
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[cfg(test)]
    pub fn active(&self) -> bool {
        self.lock().current.is_some()
    }

    /// Queue `pcm` behind any audio still playing.
    ///
    /// Never waits for the device: an idle output starts on its own thread,
    /// because AudioQueueStart blocks while CoreAudio spins the device up and
    /// a stop must not queue behind that.
    pub fn submit(
        &self,
        pcm: Box<[i16]>,
        format: PcmFormat,
        rate: f64,
    ) -> Result<Arc<Chunk>, PlaybackError> {
        let chunk = Arc::new(Chunk::new(pcm));
        let config = (format, rate.clamp(MIN_RATE, MAX_RATE));
        let mut st = self.lock();
        if st.closed {
            return Err(PlaybackError("player_closed"));
        }
        if st
            .current
            .as_ref()
            .is_some_and(|current| current.config != config)
        {
            // Format and rate are fixed per queue. A voice or rate change
            // already stops playback, so this only retires a finished tail.
            retire(&mut st);
        }
        let stream = &self.inner.stream;
        // Free what the consumer has moved past.
        let head = stream.head.load(Ordering::Acquire);
        while st.owned.front().is_some_and(|(index, _)| *index < head) {
            st.owned.pop_front();
        }
        if !chunk.is_finished() {
            let tail = stream.tail.load(Ordering::Relaxed);
            if tail - head >= RING_SLOTS {
                return Err(PlaybackError("player_busy"));
            }
            stream.slots[tail % RING_SLOTS]
                .store(Arc::as_ptr(&chunk).cast_mut(), Ordering::Release);
            st.owned.push_back((tail, chunk.clone()));
            stream.tail.store(tail + 1, Ordering::Release);
            stream
                .last_audio_at
                .store(monotonic_nanos(), Ordering::Release);
            if st.current.is_none() {
                let feed = Arc::new(Feed {
                    stream: stream.clone(),
                    attached: AtomicBool::new(true),
                });
                st.current = Some(Current {
                    feed: feed.clone(),
                    output: None,
                    config,
                });
                stream.mark_started();
                let player = self.clone();
                std::thread::Builder::new()
                    .name("speech-player-output".into())
                    .spawn(move || player.run_output(feed, config))
                    .map_err(|_| PlaybackError("playback_failed"))?;
            }
        }
        Ok(chunk)
    }

    /// Block until `chunk` has been handed to the output.
    ///
    /// Returns false when it was stopped first, and an error when the output
    /// failed, so callers never report unplayed audio as done.
    pub fn wait(&self, chunk: &Chunk, cancelled: &dyn Fn() -> bool) -> Result<bool, PlaybackError> {
        loop {
            match chunk.state.load(Ordering::Acquire) {
                DONE => return Ok(true),
                CANCELLED => return Ok(false),
                FAILED => return Err(PlaybackError("playback_failed")),
                _ => {}
            }
            if cancelled() {
                return Ok(false);
            }
            std::thread::sleep(WAIT_POLL);
        }
    }

    /// Drop queued speech and fade the output out before stopping it.
    pub fn stop(&self) {
        let mut st = self.lock();
        cancel_all(&st, CANCELLED);
        retire(&mut st);
    }

    pub fn close(&self) {
        let mut st = self.lock();
        st.closed = true;
        cancel_all(&st, CANCELLED);
        retire(&mut st);
    }

    /// Start one output, then stop it once idle or fail queued speech if it stalls.
    fn run_output(&self, feed: Arc<Feed>, config: (PcmFormat, f64)) {
        let started = (self.inner.factory)(config.0, config.1, feed.clone()).and_then(|output| {
            output
                .start()
                .map(|()| output.clone())
                .inspect_err(|_| output.dispose())
        });
        let output = match started {
            Ok(output) => output,
            Err(error) => {
                eprintln!("[speech_player] Output failed to start: {}", error.0);
                let mut st = self.lock();
                if st
                    .current
                    .as_ref()
                    .is_some_and(|current| Arc::ptr_eq(&current.feed, &feed))
                {
                    st.current = None;
                    cancel_all(&st, FAILED);
                }
                return;
            }
        };
        {
            let mut st = self.lock();
            match st.current.as_mut() {
                Some(current) if Arc::ptr_eq(&current.feed, &feed) => {
                    current.output = Some(output.clone())
                }
                _ => {
                    drop(st);
                    // Stopped while the device was starting: fade whatever was primed.
                    fade_and_dispose(&output);
                    return;
                }
            }
        }
        loop {
            std::thread::sleep(Duration::from_secs_f64(MONITOR_SECONDS));
            let mut st = self.lock();
            if !st
                .current
                .as_ref()
                .is_some_and(|current| Arc::ptr_eq(&current.feed, &feed))
            {
                return;
            }
            let stream = &self.inner.stream;
            if let Some(error) = output.error().or_else(|| {
                (Stream::seconds_since(&stream.last_render_at) > STALL_SECONDS)
                    .then(|| "no progress".to_string())
            }) {
                eprintln!("[speech_player] Output stalled: {error}");
                st.current = None;
                feed.attached.store(false, Ordering::Release);
                cancel_all(&st, FAILED);
                output.dispose();
                return;
            }
            let hold = (self.inner.keep_alive)();
            let idle_limit = if hold {
                IDLE_HOLD_SECONDS
            } else {
                IDLE_STOP_SECONDS
            };
            let pending = st.owned.iter().any(|(_, chunk)| !chunk.is_finished());
            if !pending && Stream::seconds_since(&stream.last_audio_at) > idle_limit {
                // Only silence is queued, so stopping needs no fade.
                st.current = None;
                feed.attached.store(false, Ordering::Release);
                output.dispose();
                return;
            }
        }
    }
}

fn cancel_all(st: &PlayerState, state: u8) {
    for (_, chunk) in &st.owned {
        chunk.finish(state);
    }
}

fn retire(st: &mut PlayerState) {
    let Some(current) = st.current.take() else {
        return;
    };
    current.feed.attached.store(false, Ordering::Release);
    if let Some(output) = current.output {
        fade_and_dispose(&output);
    }
    // Otherwise the device is still starting; run_output retires it.
}

fn fade_and_dispose(output: &Arc<dyn Output>) {
    output.fade_out(FADE_SECONDS);
    output.wait_faded(FADE_WAIT_TIMEOUT);
    output.dispose();
}

/// Wait for an atomic flag, polling, without holding any lock.
pub fn wait_flag(flag: &AtomicBool, timeout: f64) -> bool {
    let deadline = Instant::now() + Duration::from_secs_f64(timeout.max(0.0));
    while !flag.load(Ordering::Acquire) {
        if Instant::now() >= deadline {
            return false;
        }
        support::sleep(0.001);
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    const FMT: PcmFormat = PcmFormat::mono(24_000);

    /// Stands in for the AudioQueue: the test pumps its refill callback with a
    /// buffer it allocated once, as the device does.
    struct FakeDevice {
        feed: Arc<Feed>,
        started: AtomicBool,
        disposed: AtomicBool,
        faded: AtomicBool,
        fail_start: bool,
    }

    impl FakeDevice {
        fn pump(&self, buffers: usize) -> Vec<i16> {
            let mut buffer = vec![0i16; FMT.buffer_samples()];
            let mut heard = Vec::new();
            for _ in 0..buffers {
                if self.disposed.load(Ordering::SeqCst) {
                    break;
                }
                self.feed.render(&mut buffer);
                heard.extend_from_slice(&buffer);
            }
            heard
        }
    }

    impl Output for FakeDevice {
        fn start(&self) -> Result<(), PlaybackError> {
            if self.fail_start {
                return Err(PlaybackError("AudioQueueStart failed"));
            }
            self.started.store(true, Ordering::SeqCst);
            Ok(())
        }
        fn fade_out(&self, _seconds: f64) {
            self.faded.store(true, Ordering::SeqCst);
        }
        fn wait_faded(&self, _timeout: f64) -> bool {
            true
        }
        fn dispose(&self) {
            self.disposed.store(true, Ordering::SeqCst);
        }
        fn error(&self) -> Option<String> {
            None
        }
    }

    /// Every output the player created, with the format and rate it was given.
    type Devices = Arc<Mutex<Vec<(Arc<FakeDevice>, PcmFormat, f64)>>>;

    struct Rig {
        player: SpeechPlayer,
        devices: Devices,
    }

    fn rig(fail_start: bool) -> Rig {
        let devices: Devices = Arc::default();
        let created = devices.clone();
        let player = SpeechPlayer::new(
            Box::new(move |format, rate, feed| {
                let device = Arc::new(FakeDevice {
                    feed,
                    started: AtomicBool::new(false),
                    disposed: AtomicBool::new(false),
                    faded: AtomicBool::new(false),
                    fail_start,
                });
                created.lock().unwrap().push((device.clone(), format, rate));
                Ok(device as Arc<dyn Output>)
            }),
            Box::new(|| false),
        );
        Rig { player, devices }
    }

    impl Rig {
        fn device(&self, index: usize) -> Arc<FakeDevice> {
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                if let Some((device, _, _)) = self.devices.lock().unwrap().get(index)
                    && (device.started.load(Ordering::SeqCst) || device.fail_start)
                {
                    return device.clone();
                }
                assert!(Instant::now() < deadline, "no output {index}");
                std::thread::sleep(Duration::from_millis(1));
            }
        }
    }

    fn tone(len: usize, value: i16) -> Box<[i16]> {
        vec![value; len].into_boxed_slice()
    }

    #[test]
    fn sentences_join_one_gapless_stream_on_one_output() {
        let rig = rig(false);
        let first = rig.player.submit(tone(700, 1), FMT, 1.0).unwrap();
        let device = rig.device(0);
        let second = rig.player.submit(tone(300, 2), FMT, 1.0).unwrap();
        // 480-sample buffers: 700 + 300 samples fill two buffers and part of a third.
        let heard = device.pump(3);
        assert_eq!(&heard[..700], &[1; 700][..]);
        assert_eq!(&heard[700..1000], &[2; 300][..]);
        assert!(
            heard[1000..].iter().all(|sample| *sample == 0),
            "missing audio is silence"
        );
        assert_eq!(rig.player.wait(&first, &|| false), Ok(true));
        assert_eq!(rig.player.wait(&second, &|| false), Ok(true));
        assert_eq!(
            rig.devices.lock().unwrap().len(),
            1,
            "the device started once"
        );
    }

    #[test]
    fn a_chunk_is_done_only_once_its_last_sample_is_handed_off() {
        let rig = rig(false);
        let chunk = rig.player.submit(tone(1000, 3), FMT, 1.0).unwrap();
        let device = rig.device(0);
        device.pump(2);
        assert!(!chunk.is_finished());
        device.pump(1);
        assert!(chunk.is_finished());
    }

    #[test]
    fn stop_fades_the_output_and_cancels_queued_audio() {
        let rig = rig(false);
        let chunk = rig.player.submit(tone(24_000, 4), FMT, 1.3).unwrap();
        let device = rig.device(0);
        device.pump(1);
        rig.player.stop();
        assert!(device.faded.load(Ordering::SeqCst) && device.disposed.load(Ordering::SeqCst));
        assert_eq!(rig.player.wait(&chunk, &|| false), Ok(false));
        // A retired feed renders only silence.
        let mut buffer = vec![9i16; FMT.buffer_samples()];
        device.feed.render(&mut buffer);
        assert!(buffer.iter().all(|sample| *sample == 0));
        // The next sentence starts a new output, which skips the cancelled one.
        let next = rig.player.submit(tone(10, 5), FMT, 1.3).unwrap();
        let heard = rig.device(1).pump(1);
        assert_eq!(&heard[..10], &[5; 10][..]);
        assert_eq!(rig.player.wait(&next, &|| false), Ok(true));
    }

    #[test]
    fn rate_is_clamped_and_a_new_rate_needs_a_new_output() {
        let rig = rig(false);
        rig.player.submit(tone(10, 1), FMT, 3.0).unwrap();
        rig.device(0).pump(1);
        rig.player.submit(tone(10, 1), FMT, 0.1).unwrap();
        rig.device(1);
        let devices = rig.devices.lock().unwrap();
        assert_eq!((devices[0].2, devices[1].2), (MAX_RATE, MIN_RATE));
        assert!(devices[0].0.disposed.load(Ordering::SeqCst));
    }

    #[test]
    fn an_output_that_cannot_start_fails_its_audio() {
        let rig = rig(true);
        let chunk = rig.player.submit(tone(10, 1), FMT, 1.0).unwrap();
        assert_eq!(
            rig.player.wait(&chunk, &|| false),
            Err(PlaybackError("playback_failed"))
        );
        assert!(!rig.player.active());
    }

    #[test]
    fn wait_returns_when_its_caller_cancels() {
        let rig = rig(false);
        let chunk = rig.player.submit(tone(10, 1), FMT, 1.0).unwrap();
        let polls = AtomicUsize::new(0);
        assert_eq!(
            rig.player
                .wait(&chunk, &|| polls.fetch_add(1, Ordering::SeqCst) > 1),
            Ok(false)
        );
    }

    #[test]
    fn a_closed_player_refuses_audio_and_empty_audio_is_done_at_once() {
        let rig = rig(false);
        let empty = rig.player.submit(Box::new([]), FMT, 1.0).unwrap();
        assert!(empty.is_finished());
        assert!(
            rig.devices.lock().unwrap().is_empty(),
            "silence starts no output"
        );
        rig.player.close();
        assert_eq!(
            rig.player.submit(tone(10, 1), FMT, 1.0).err(),
            Some(PlaybackError("player_closed"))
        );
    }

    #[test]
    fn finished_chunks_are_freed_once_the_consumer_passed_them() {
        let rig = rig(false);
        let chunk = rig.player.submit(tone(10, 1), FMT, 1.0).unwrap();
        rig.device(0).pump(1);
        assert!(chunk.is_finished());
        rig.player.submit(tone(10, 1), FMT, 1.0).unwrap();
        assert_eq!(
            Arc::strong_count(&chunk),
            1,
            "the player let go of the played chunk"
        );
    }

    #[test]
    fn a_second_consumer_renders_silence_instead_of_racing() {
        let stream = Stream::new();
        stream.consumer.store(true, Ordering::SeqCst);
        let mut buffer = vec![7i16; 16];
        stream.render(&mut buffer);
        assert!(buffer.iter().all(|sample| *sample == 0));
    }
}
