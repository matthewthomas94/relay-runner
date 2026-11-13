//! One AudioToolbox output queue at a fixed format and rate, through FFI: the
//! twin of `AudioQueueOutput` in `services/speech_player.py`.
//!
//! `rate` uses the queue's Time Domain time-pitch processor, the algorithm
//! `afplay -r` uses, so tempo changes without a pitch shift; at 1.0 it is
//! bypassed and the audio is untouched. The refill callback runs on the
//! queue's own thread and only renders into the buffer it is given and
//! enqueues it again: no allocation and no lock.

use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicPtr, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use crate::player::{
    BUFFER_COUNT, FADE_SETTLE_SECONDS, Feed, Output, PcmFormat, PlaybackError, wait_flag,
};
use crate::support::monotonic_nanos;

type AudioQueueRef = *mut c_void;
type OsStatus = i32;

#[repr(C)]
struct AudioStreamBasicDescription {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
}

#[repr(C)]
struct AudioQueueBuffer {
    audio_data_bytes_capacity: u32,
    audio_data: *mut c_void,
    audio_data_byte_size: u32,
    user_data: *mut c_void,
    packet_description_capacity: u32,
    packet_descriptions: *mut c_void,
    packet_description_count: u32,
}

type OutputCallback = extern "C" fn(*mut c_void, AudioQueueRef, *mut AudioQueueBuffer);

#[link(name = "AudioToolbox", kind = "framework")]
unsafe extern "C" {
    fn AudioQueueNewOutput(
        format: *const AudioStreamBasicDescription,
        callback: OutputCallback,
        user_data: *mut c_void,
        run_loop: *const c_void,
        run_loop_mode: *const c_void,
        flags: u32,
        queue: *mut AudioQueueRef,
    ) -> OsStatus;
    fn AudioQueueAllocateBuffer(
        queue: AudioQueueRef,
        bytes: u32,
        buffer: *mut *mut AudioQueueBuffer,
    ) -> OsStatus;
    fn AudioQueueEnqueueBuffer(
        queue: AudioQueueRef,
        buffer: *mut AudioQueueBuffer,
        packets: u32,
        descriptions: *const c_void,
    ) -> OsStatus;
    fn AudioQueueStart(queue: AudioQueueRef, start_time: *const c_void) -> OsStatus;
    fn AudioQueueDispose(queue: AudioQueueRef, immediate: u8) -> OsStatus;
    fn AudioQueueSetParameter(queue: AudioQueueRef, parameter: u32, value: f32) -> OsStatus;
    fn AudioQueueSetProperty(
        queue: AudioQueueRef,
        property: u32,
        data: *const c_void,
        size: u32,
    ) -> OsStatus;
}

const fn fourcc(code: &[u8; 4]) -> u32 {
    u32::from_be_bytes(*code)
}

const LINEAR_PCM: u32 = fourcc(b"lpcm");
/// kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked.
const SIGNED_PACKED: u32 = 0x4 | 0x8;
const ENABLE_TIME_PITCH: u32 = fourcc(b"q_tp");
const TIME_PITCH_ALGORITHM: u32 = fourcc(b"qtpa");
const TIME_PITCH_BYPASS: u32 = fourcc(b"qtpb");
/// kAudioQueueTimePitchAlgorithm_TimeDomain, afplay's default.
const TIME_DOMAIN: u32 = fourcc(b"tido");
const PARAM_VOLUME: u32 = 1;
const PARAM_PLAY_RATE: u32 = 2;
const PARAM_VOLUME_RAMP_TIME: u32 = 4;

/// What the refill callback reads. It outlives every callback: it is freed
/// only after the synchronous `AudioQueueDispose` has returned.
struct Context {
    feed: Arc<Feed>,
    queue: AtomicPtr<c_void>,
    running: AtomicBool,
    samples: usize,
    bytes: u32,
    fade_deadline: AtomicU64,
    faded: AtomicBool,
    error: AtomicI32,
}

extern "C" fn refill(user_data: *mut c_void, queue: AudioQueueRef, buffer: *mut AudioQueueBuffer) {
    // SAFETY: user_data is the Context, alive until after AudioQueueDispose.
    let context = unsafe { &*(user_data as *const Context) };
    if !context.running.load(Ordering::Acquire) || queue != context.queue.load(Ordering::Acquire) {
        return;
    }
    // SAFETY: the buffer was allocated for `bytes` and belongs to this queue.
    unsafe { fill(context, buffer) };
    // SAFETY: re-enqueueing the buffer AudioQueue handed back.
    let status = unsafe { AudioQueueEnqueueBuffer(queue, buffer, 0, std::ptr::null()) };
    if status != 0 {
        // Leave recovery to the monitor; never unwind into AudioToolbox.
        context.error.store(status, Ordering::Release);
        context.running.store(false, Ordering::Release);
        return;
    }
    let deadline = context.fade_deadline.load(Ordering::Acquire);
    if deadline != 0 && monotonic_nanos() >= deadline {
        context.faded.store(true, Ordering::Release);
    }
}

/// # Safety
/// `buffer` must hold at least `context.bytes` bytes of audio data.
unsafe fn fill(context: &Context, buffer: *mut AudioQueueBuffer) {
    // SAFETY: per the contract above; i16 alignment holds for AudioQueue buffers.
    unsafe {
        let samples =
            std::slice::from_raw_parts_mut((*buffer).audio_data.cast::<i16>(), context.samples);
        context.feed.render(samples);
        (*buffer).audio_data_byte_size = context.bytes;
    }
}

fn check(status: OsStatus, call: &'static str) -> Result<(), PlaybackError> {
    if status == 0 {
        Ok(())
    } else {
        eprintln!("[speech_player] {call} failed ({status})");
        Err(PlaybackError("playback_failed"))
    }
}

pub struct AudioQueueOutput {
    context: *mut Context,
    buffers: Vec<*mut AudioQueueBuffer>,
    disposed: Mutex<bool>,
}

// SAFETY: the raw pointers are only used through AudioToolbox calls, which
// are thread-safe for one queue, and the Context's fields are atomics.
unsafe impl Send for AudioQueueOutput {}
unsafe impl Sync for AudioQueueOutput {}

impl AudioQueueOutput {
    pub fn create(
        format: PcmFormat,
        rate: f64,
        feed: Arc<Feed>,
    ) -> Result<Arc<dyn Output>, PlaybackError> {
        let samples = format.buffer_samples();
        let bytes = u32::try_from(samples * 2).map_err(|_| PlaybackError("playback_failed"))?;
        let context = Box::into_raw(Box::new(Context {
            feed,
            queue: AtomicPtr::new(std::ptr::null_mut()),
            running: AtomicBool::new(false),
            samples,
            bytes,
            fade_deadline: AtomicU64::new(0),
            faded: AtomicBool::new(false),
            error: AtomicI32::new(0),
        }));
        let output = Self {
            context,
            buffers: Vec::new(),
            disposed: Mutex::new(false),
        };
        let description = AudioStreamBasicDescription {
            sample_rate: f64::from(format.sample_rate),
            format_id: LINEAR_PCM,
            format_flags: SIGNED_PACKED,
            bytes_per_packet: format.frame_bytes() as u32,
            frames_per_packet: 1,
            bytes_per_frame: format.frame_bytes() as u32,
            channels_per_frame: u32::from(format.channels),
            bits_per_channel: 16,
            reserved: 0,
        };
        let mut queue: AudioQueueRef = std::ptr::null_mut();
        // SAFETY: valid description and out-pointer; no run loop, so callbacks
        // arrive on the queue's own thread.
        check(
            unsafe {
                AudioQueueNewOutput(
                    &description,
                    refill,
                    context.cast(),
                    std::ptr::null(),
                    std::ptr::null(),
                    0,
                    &mut queue,
                )
            },
            "AudioQueueNewOutput",
        )?;
        // SAFETY: context is live.
        unsafe { (*context).queue.store(queue, Ordering::Release) };
        let mut output = output;
        output.configure(queue, rate)?;
        Ok(Arc::new(output))
    }

    fn context(&self) -> &Context {
        // SAFETY: freed only in Drop.
        unsafe { &*self.context }
    }

    fn queue(&self) -> AudioQueueRef {
        self.context().queue.load(Ordering::Acquire)
    }

    fn configure(&mut self, queue: AudioQueueRef, rate: f64) -> Result<(), PlaybackError> {
        let set = |property: u32, value: u32| {
            // SAFETY: a 4-byte property value.
            check(
                unsafe { AudioQueueSetProperty(queue, property, (&raw const value).cast(), 4) },
                "AudioQueueSetProperty",
            )
        };
        set(ENABLE_TIME_PITCH, 1)?;
        set(TIME_PITCH_ALGORITHM, TIME_DOMAIN)?;
        // afplay does not time-stretch at 1.0; bypass leaves that audio untouched.
        set(TIME_PITCH_BYPASS, u32::from(rate == 1.0))?;
        // SAFETY: a valid queue.
        check(
            unsafe { AudioQueueSetParameter(queue, PARAM_PLAY_RATE, rate as f32) },
            "AudioQueueSetParameter",
        )?;
        for _ in 0..BUFFER_COUNT {
            let mut buffer: *mut AudioQueueBuffer = std::ptr::null_mut();
            // SAFETY: allocating a buffer of the size the callback fills.
            check(
                unsafe { AudioQueueAllocateBuffer(queue, self.context().bytes, &mut buffer) },
                "AudioQueueAllocateBuffer",
            )?;
            self.buffers.push(buffer);
        }
        Ok(())
    }
}

impl Output for AudioQueueOutput {
    fn start(&self) -> Result<(), PlaybackError> {
        let queue = self.queue();
        self.context().running.store(true, Ordering::Release);
        for &buffer in &self.buffers {
            // SAFETY: buffers belong to this queue and hold `bytes` bytes.
            unsafe { fill(self.context(), buffer) };
            // SAFETY: enqueueing a primed buffer.
            check(
                unsafe { AudioQueueEnqueueBuffer(queue, buffer, 0, std::ptr::null()) },
                "AudioQueueEnqueueBuffer",
            )?;
        }
        // SAFETY: a configured queue; blocks while the device spins up.
        check(
            unsafe { AudioQueueStart(queue, std::ptr::null()) },
            "AudioQueueStart",
        )
    }

    fn fade_out(&self, seconds: f64) {
        let queue = self.queue();
        if queue.is_null() {
            return;
        }
        // SAFETY: a live queue.
        unsafe {
            AudioQueueSetParameter(queue, PARAM_VOLUME_RAMP_TIME, seconds as f32);
            AudioQueueSetParameter(queue, PARAM_VOLUME, 0.0);
        }
        let deadline = monotonic_nanos() + ((seconds + FADE_SETTLE_SECONDS) * 1e9) as u64;
        self.context()
            .fade_deadline
            .store(deadline, Ordering::Release);
    }

    /// The refill callback, paced by the device, signals the end of the ramp,
    /// so a coalesced timer in a background process cannot stretch the stop.
    fn wait_faded(&self, timeout: f64) -> bool {
        wait_flag(&self.context().faded, timeout)
    }

    fn dispose(&self) {
        let mut disposed = self
            .disposed
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if *disposed {
            return;
        }
        *disposed = true;
        let context = self.context();
        context.running.store(false, Ordering::Release);
        let queue = context.queue.swap(std::ptr::null_mut(), Ordering::AcqRel);
        if !queue.is_null() {
            // SAFETY: synchronous: no callback runs after this returns.
            unsafe { AudioQueueDispose(queue, 1) };
        }
    }

    fn error(&self) -> Option<String> {
        match self.context().error.load(Ordering::Acquire) {
            0 => None,
            status => Some(format!("AudioQueueEnqueueBuffer failed ({status})")),
        }
    }
}

impl Drop for AudioQueueOutput {
    fn drop(&mut self) {
        self.dispose();
        // SAFETY: the queue is disposed, so no callback can read the context.
        drop(unsafe { Box::from_raw(self.context) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::player::SpeechPlayer;
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::cell::Cell;
    use std::time::{Duration, Instant};

    thread_local! {
        static WATCHED: Cell<bool> = const { Cell::new(false) };
        static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
    }

    /// Counts the allocations a thread makes while it is watched.
    struct Counting;

    // SAFETY: forwards to the system allocator.
    unsafe impl GlobalAlloc for Counting {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            if WATCHED.with(Cell::get) {
                ALLOCATIONS.with(|count| count.set(count.get() + 1));
            }
            // SAFETY: as GlobalAlloc::alloc.
            unsafe { System.alloc(layout) }
        }
        unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
            // SAFETY: as GlobalAlloc::dealloc.
            unsafe { System.dealloc(ptr, layout) }
        }
    }

    #[global_allocator]
    static ALLOCATOR: Counting = Counting;

    /// Stands in for the device behind the AudioQueue: it starts and stops,
    /// and the test calls the queue's refill code with buffers of its own.
    struct FakeDevice;

    impl Output for FakeDevice {
        fn start(&self) -> Result<(), PlaybackError> {
            Ok(())
        }
        fn fade_out(&self, _seconds: f64) {}
        fn wait_faded(&self, _timeout: f64) -> bool {
            true
        }
        fn dispose(&self) {}
        fn error(&self) -> Option<String> {
            None
        }
    }

    const FORMAT: PcmFormat = PcmFormat::mono(24_000);

    /// A player whose output is the fake device, and the feed it was given.
    fn feed_with(pcm: &[i16]) -> (SpeechPlayer, Arc<Feed>) {
        let feed: Arc<Mutex<Option<Arc<Feed>>>> = Arc::default();
        let created = feed.clone();
        let player = SpeechPlayer::new(
            Box::new(move |_, _, feed| {
                *created.lock().unwrap() = Some(feed);
                Ok(Arc::new(FakeDevice) as Arc<dyn Output>)
            }),
            Box::new(|| false),
        );
        player.submit(pcm.into(), FORMAT, 1.0).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(feed) = feed.lock().unwrap().clone() {
                return (player, feed);
            }
            assert!(Instant::now() < deadline, "the output was never created");
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    fn context(feed: Arc<Feed>, queue: AudioQueueRef, running: bool) -> Context {
        let samples = FORMAT.buffer_samples();
        Context {
            feed,
            queue: AtomicPtr::new(queue),
            running: AtomicBool::new(running),
            samples,
            bytes: (samples * 2) as u32,
            fade_deadline: AtomicU64::new(0),
            faded: AtomicBool::new(false),
            error: AtomicI32::new(0),
        }
    }

    fn buffer(data: &mut [i16]) -> AudioQueueBuffer {
        AudioQueueBuffer {
            audio_data_bytes_capacity: (data.len() * 2) as u32,
            audio_data: data.as_mut_ptr().cast(),
            audio_data_byte_size: 0,
            user_data: std::ptr::null_mut(),
            packet_description_capacity: 0,
            packet_descriptions: std::ptr::null_mut(),
            packet_description_count: 0,
        }
    }

    #[test]
    fn a_refill_renders_the_stream_into_the_buffer_without_allocating() {
        let speech: Vec<i16> = (1..=700).collect();
        let (_player, feed) = feed_with(&speech);
        let context = context(feed, std::ptr::null_mut(), true);
        let mut first = vec![-1i16; FORMAT.buffer_samples()];
        let mut second = vec![-1i16; FORMAT.buffer_samples()];
        let (mut first_buffer, mut second_buffer) = (buffer(&mut first), buffer(&mut second));
        WATCHED.with(|watched| watched.set(true));
        // SAFETY: each buffer holds `context.bytes` bytes.
        unsafe {
            fill(&context, &mut first_buffer);
            fill(&context, &mut second_buffer);
        }
        WATCHED.with(|watched| watched.set(false));
        assert_eq!(ALLOCATIONS.with(Cell::get), 0, "the refill path allocated");
        assert_eq!(
            (
                first_buffer.audio_data_byte_size,
                second_buffer.audio_data_byte_size
            ),
            (960, 960)
        );
        // 480-sample buffers: the sentence continues across them, then silence.
        assert_eq!(&first[..], &speech[..480]);
        assert_eq!(&second[..220], &speech[480..]);
        assert!(second[220..].iter().all(|sample| *sample == 0));
    }

    /// Opens the Mac's real output and plays silence through it, so nothing
    /// is heard. Run with `cargo test -p relay-speech -- --ignored`.
    #[test]
    #[ignore = "opens the audio device"]
    fn silence_plays_to_its_end_through_a_real_audio_queue_and_a_stop_fades_it() {
        let player = SpeechPlayer::new(Box::new(AudioQueueOutput::create), Box::new(|| true));
        // 0.3 s at 1.3x through the time-pitch processor, then 0.2 s more on the same queue.
        let first = player.submit(vec![0; 7_200].into(), FORMAT, 1.3).unwrap();
        let second = player.submit(vec![0; 4_800].into(), FORMAT, 1.3).unwrap();
        let started = Instant::now();
        assert_eq!(
            player.wait(&first, &|| started.elapsed() > Duration::from_secs(5)),
            Ok(true)
        );
        assert_eq!(
            player.wait(&second, &|| started.elapsed() > Duration::from_secs(5)),
            Ok(true)
        );
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "the queue did not play in real time"
        );
        let long = player.submit(vec![0; 240_000].into(), FORMAT, 1.3).unwrap();
        std::thread::sleep(Duration::from_millis(100));
        let stopping = Instant::now();
        player.stop();
        assert!(
            stopping.elapsed() < Duration::from_millis(500),
            "the fade did not finish"
        );
        assert_eq!(player.wait(&long, &|| false), Ok(false));
        player.close();
    }

    #[test]
    fn a_callback_for_a_stopped_or_replaced_queue_touches_nothing() {
        let (_player, feed) = feed_with(&[5; 100]);
        let mut data = vec![-1i16; FORMAT.buffer_samples()];
        let queue = std::ptr::dangling_mut::<c_void>();
        for (running, current) in [(false, queue), (true, std::ptr::null_mut())] {
            let context = context(feed.clone(), current, running);
            let mut buffer = buffer(&mut data);
            // The early return is taken before AudioToolbox is called, so a
            // fake queue pointer is never dereferenced.
            refill((&raw const context).cast_mut().cast(), queue, &mut buffer);
            assert_eq!(buffer.audio_data_byte_size, 0);
        }
        assert!(data.iter().all(|sample| *sample == -1));
    }
}
