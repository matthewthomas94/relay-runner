"""Persistent speech output for the TTS worker (RR-438).

Relay used to start a fresh ``afplay`` process for every synthesized sentence,
so CoreAudio tore the output device down and re-created it between sentences.
Each restart risked an "Audio IO Overload" in coreaudiod, audible as a click in
everything playing at that moment.

``SpeechPlayer`` keeps one AudioToolbox output queue running for a reply:

* sentence chunks are appended to one PCM stream, so boundaries are gapless and
  the device starts at most once per reply;
* ``rate`` uses the queue's Time Domain time-pitch processor, the algorithm
  ``afplay -r`` uses by default, so tempo changes without a pitch shift;
* ``stop()`` ramps the queue's output volume to zero over ``FADE_SECONDS`` and
  then stops it, instead of killing a process mid-buffer;
* after ``IDLE_STOP_SECONDS`` of silence the queue stops, so an idle session
  does not keep the speaker running.

The queue lives in this process: playback adds no helper process, Python
dependency, or bundled binary. AudioQueue invokes the refill callback on its
own non-real-time thread, so Python never runs on the device IO thread.
"""

from __future__ import annotations

import atexit
import ctypes
import struct
import sys
import threading
import time
import wave
from collections import deque
from dataclasses import dataclass, field

FADE_SECONDS = 0.02
# Stop the queue only after the ramp has reached the output.
FADE_SETTLE_SECONDS = 0.015
# Upper bound on waiting for the ramp if the output stops calling back.
FADE_WAIT_TIMEOUT = 0.1
IDLE_STOP_SECONDS = 2.0
# While the worker is still inside a reply, a slow next-chunk render (custom
# voices convert serially) should not restart the device mid-reply.
IDLE_HOLD_SECONDS = 15.0
STALL_SECONDS = 2.0
MONITOR_SECONDS = 0.1
BUFFER_SECONDS = 0.02
BUFFER_COUNT = 4
MIN_RATE, MAX_RATE = 0.5, 2.0
TIME_PITCH_ALGORITHM = "tido"


class SpeechPlaybackError(RuntimeError):
    """Speech output could not start or stopped making progress."""


@dataclass(frozen=True)
class PcmFormat:
    sample_rate: int
    channels: int = 1
    sample_width: int = 2

    @property
    def frame_bytes(self) -> int:
        return self.channels * self.sample_width


def read_wav(path: str) -> tuple[bytes, PcmFormat]:
    """Read a 16-bit PCM WAV, as written by the TTS worker."""
    try:
        with wave.open(path, "rb") as source:
            fmt = PcmFormat(source.getframerate(), source.getnchannels(), source.getsampwidth())
            pcm = source.readframes(source.getnframes())
    except (OSError, EOFError, wave.Error) as exc:
        raise SpeechPlaybackError("unreadable_audio") from exc
    if fmt.sample_width != 2 or fmt.channels not in (1, 2) or fmt.sample_rate <= 0:
        raise SpeechPlaybackError("unsupported_audio")
    return pcm, fmt


@dataclass(eq=False)
class SpeechChunk:
    """One submitted sentence; ``done`` is set once it has been handed to the output."""

    pcm: bytes
    position: int = 0
    cancelled: bool = False
    error: str | None = None
    done: threading.Event = field(default_factory=threading.Event)


class SpeechStream:
    """Ordered PCM chunks rendered as one continuous stream."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._chunks: deque[SpeechChunk] = deque()
        now = time.monotonic()
        self.last_render_at = now
        self.last_audio_at = now

    @property
    def pending(self) -> bool:
        with self._lock:
            return bool(self._chunks)

    def submit(self, chunk: SpeechChunk) -> None:
        with self._lock:
            if not chunk.pcm:
                chunk.done.set()
                return
            self._chunks.append(chunk)
            self.last_audio_at = time.monotonic()

    def mark_started(self) -> None:
        with self._lock:
            self.last_render_at = self.last_audio_at = time.monotonic()

    def render(self, size: int) -> bytes:
        """Return the next ``size`` bytes of the stream; missing audio is silence."""
        out = bytearray()
        handed_off = []
        with self._lock:
            now = time.monotonic()
            self.last_render_at = now
            while len(out) < size and self._chunks:
                chunk = self._chunks[0]
                take = chunk.pcm[chunk.position:chunk.position + size - len(out)]
                out += take
                chunk.position += len(take)
                if chunk.position >= len(chunk.pcm):
                    handed_off.append(self._chunks.popleft())
            if out:
                self.last_audio_at = now
        for chunk in handed_off:
            chunk.done.set()
        out += bytes(size - len(out))
        return bytes(out)

    def cancel_all(self, error: str | None = None) -> None:
        with self._lock:
            chunks = list(self._chunks)
            self._chunks.clear()
        for chunk in chunks:
            chunk.cancelled = True
            chunk.error = error
            chunk.done.set()


def _fourcc(code: str) -> int:
    return struct.unpack(">I", code.encode("ascii"))[0]


class _ASBD(ctypes.Structure):
    _fields_ = [
        ("mSampleRate", ctypes.c_double),
        ("mFormatID", ctypes.c_uint32),
        ("mFormatFlags", ctypes.c_uint32),
        ("mBytesPerPacket", ctypes.c_uint32),
        ("mFramesPerPacket", ctypes.c_uint32),
        ("mBytesPerFrame", ctypes.c_uint32),
        ("mChannelsPerFrame", ctypes.c_uint32),
        ("mBitsPerChannel", ctypes.c_uint32),
        ("mReserved", ctypes.c_uint32),
    ]


class _AQBuffer(ctypes.Structure):
    _fields_ = [
        ("mAudioDataBytesCapacity", ctypes.c_uint32),
        ("mAudioData", ctypes.c_void_p),
        ("mAudioDataByteSize", ctypes.c_uint32),
        ("mUserData", ctypes.c_void_p),
        ("mPacketDescriptionCapacity", ctypes.c_uint32),
        ("mPacketDescriptions", ctypes.c_void_p),
        ("mPacketDescriptionCount", ctypes.c_uint32),
    ]


_OUTPUT_CALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(_AQBuffer))
_K_LPCM = _fourcc("lpcm")
_K_SIGNED_PACKED = 0x4 | 0x8
_K_ENABLE_TIME_PITCH = _fourcc("q_tp")
_K_TIME_PITCH_ALGORITHM = _fourcc("qtpa")
_K_TIME_PITCH_BYPASS = _fourcc("qtpb")
_K_PARAM_VOLUME = 1
_K_PARAM_PLAY_RATE = 2
_K_PARAM_VOLUME_RAMP_TIME = 4
_audio_toolbox_lib = None


def _audio_toolbox():
    global _audio_toolbox_lib
    if _audio_toolbox_lib is None:
        if sys.platform != "darwin":
            raise SpeechPlaybackError("audio_unavailable")
        try:
            lib = ctypes.CDLL("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")
        except OSError as exc:
            raise SpeechPlaybackError("audio_unavailable") from exc
        queue, status = ctypes.c_void_p, ctypes.c_int32
        lib.AudioQueueNewOutput.argtypes = [
            ctypes.POINTER(_ASBD), _OUTPUT_CALLBACK, ctypes.c_void_p, ctypes.c_void_p,
            ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(queue),
        ]
        lib.AudioQueueAllocateBuffer.argtypes = [queue, ctypes.c_uint32, ctypes.POINTER(ctypes.POINTER(_AQBuffer))]
        lib.AudioQueueEnqueueBuffer.argtypes = [queue, ctypes.POINTER(_AQBuffer), ctypes.c_uint32, ctypes.c_void_p]
        lib.AudioQueueStart.argtypes = [queue, ctypes.c_void_p]
        lib.AudioQueueDispose.argtypes = [queue, ctypes.c_bool]
        lib.AudioQueueSetParameter.argtypes = [queue, ctypes.c_uint32, ctypes.c_float]
        lib.AudioQueueSetProperty.argtypes = [queue, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32]
        for name in ("AudioQueueNewOutput", "AudioQueueAllocateBuffer", "AudioQueueEnqueueBuffer",
                     "AudioQueueStart", "AudioQueueDispose", "AudioQueueSetParameter", "AudioQueueSetProperty"):
            getattr(lib, name).restype = status
        _audio_toolbox_lib = lib
    return _audio_toolbox_lib


def _check(status: int, call: str) -> None:
    if status:
        raise SpeechPlaybackError(f"{call} failed ({status})")


class AudioQueueOutput:
    """One AudioToolbox output queue at a fixed format and rate.

    ``dispose()`` ends the queue and its callbacks. The refill callback only
    renders and re-enqueues; it never reconfigures the queue.
    """

    def __init__(self, fmt: PcmFormat, rate: float, render, *, buffer_count: int = BUFFER_COUNT):
        self._at = _audio_toolbox()
        self._render = render
        self._buffer_bytes = max(1, round(fmt.sample_rate * BUFFER_SECONDS)) * fmt.frame_bytes
        # The callback object must outlive every callback AudioQueue can make.
        self._callback = _OUTPUT_CALLBACK(self._refill)
        self._running = False
        self._fade_deadline: float | None = None
        self._faded = threading.Event()
        self.error: str | None = None
        asbd = _ASBD(float(fmt.sample_rate), _K_LPCM, _K_SIGNED_PACKED, fmt.frame_bytes, 1,
                     fmt.frame_bytes, fmt.channels, fmt.sample_width * 8, 0)
        handle = ctypes.c_void_p()
        _check(self._at.AudioQueueNewOutput(ctypes.byref(asbd), self._callback, None, None, None, 0,
                                            ctypes.byref(handle)), "AudioQueueNewOutput")
        self._queue = handle.value
        try:
            self._set_property(_K_ENABLE_TIME_PITCH, 1)
            self._set_property(_K_TIME_PITCH_ALGORITHM, _fourcc(TIME_PITCH_ALGORITHM))
            # afplay does not time-stretch at 1.0; bypass leaves that audio untouched.
            self._set_property(_K_TIME_PITCH_BYPASS, int(rate == 1.0))
            _check(self._at.AudioQueueSetParameter(self._queue, _K_PARAM_PLAY_RATE, rate), "AudioQueueSetParameter")
            self._buffers = []
            for _ in range(buffer_count):
                buffer = ctypes.POINTER(_AQBuffer)()
                _check(self._at.AudioQueueAllocateBuffer(self._queue, self._buffer_bytes, ctypes.byref(buffer)),
                       "AudioQueueAllocateBuffer")
                self._buffers.append(buffer)
        except Exception:
            self.dispose()
            raise

    @property
    def queue(self) -> int | None:
        return self._queue

    def _set_property(self, prop: int, value: int) -> None:
        data = ctypes.c_uint32(value)
        _check(self._at.AudioQueueSetProperty(self._queue, prop, ctypes.byref(data), 4), "AudioQueueSetProperty")

    def fade_out(self, seconds: float = FADE_SECONDS) -> None:
        """Ramp the output volume to zero; it applies to audio already queued."""
        self._at.AudioQueueSetParameter(self._queue, _K_PARAM_VOLUME_RAMP_TIME, seconds)
        self._at.AudioQueueSetParameter(self._queue, _K_PARAM_VOLUME, 0.0)
        self._fade_deadline = time.monotonic() + seconds + FADE_SETTLE_SECONDS

    def wait_faded(self, timeout: float) -> bool:
        """Wait until the ramp has played out.

        The refill callback, paced by the device, signals completion, so a
        coalesced timer in a background process cannot stretch the stop.
        """
        return self._faded.wait(timeout)

    def start(self) -> None:
        self._running = True
        for buffer in self._buffers:
            self._fill(buffer)
            _check(self._at.AudioQueueEnqueueBuffer(self._queue, buffer, 0, None), "AudioQueueEnqueueBuffer")
        _check(self._at.AudioQueueStart(self._queue, None), "AudioQueueStart")

    def dispose(self) -> None:
        self._running = False
        queue, self._queue = self._queue, None
        if queue:
            # Synchronous: no callback runs after this returns.
            self._at.AudioQueueDispose(queue, True)

    def _fill(self, buffer) -> None:
        data = self._render(self._buffer_bytes)
        ctypes.memmove(buffer.contents.mAudioData, data, len(data))
        buffer.contents.mAudioDataByteSize = len(data)

    def _refill(self, _user, queue, buffer) -> None:
        if not self._running or queue != self._queue:
            return
        try:
            self._fill(buffer)
            _check(self._at.AudioQueueEnqueueBuffer(queue, buffer, 0, None), "AudioQueueEnqueueBuffer")
            deadline = self._fade_deadline
            if deadline is not None and time.monotonic() >= deadline:
                self._faded.set()
        except Exception as exc:
            # Leave recovery to the monitor; never raise into AudioToolbox.
            self.error = str(exc) or type(exc).__name__
            self._running = False


class _Feed:
    """Connects one output to the shared stream until that output is retired."""

    def __init__(self, stream: SpeechStream):
        self._stream = stream
        self.attached = True
        self.output = None

    def __call__(self, size: int) -> bytes:
        # A retired output keeps rendering only silence while it fades out.
        return self._stream.render(size) if self.attached else bytes(size)


class SpeechPlayer:
    """Plays sentence chunks through one output queue that survives across a reply."""

    def __init__(self, *, keep_alive=lambda: False, output_factory=AudioQueueOutput):
        self._keep_alive = keep_alive
        self._output_factory = output_factory
        self._lock = threading.RLock()
        self._stream = SpeechStream()
        self._feed: _Feed | None = None
        self._config: tuple[PcmFormat, float] | None = None
        self._closed = False
        atexit.register(self.close)

    @property
    def active(self) -> bool:
        return self._feed is not None

    def submit_wav(self, path: str, rate: float) -> SpeechChunk:
        pcm, fmt = read_wav(path)
        return self.submit(pcm, fmt, rate)

    def submit(self, pcm: bytes, fmt: PcmFormat, rate: float) -> SpeechChunk:
        """Queue ``pcm`` behind any audio still playing.

        Never waits for the device: an idle output starts on its own thread,
        because AudioQueueStart blocks while CoreAudio spins the device up and
        a stop must not queue behind that.
        """
        chunk = SpeechChunk(pcm)
        config = (fmt, min(MAX_RATE, max(MIN_RATE, float(rate))))
        with self._lock:
            if self._closed:
                raise SpeechPlaybackError("player_closed")
            if self._feed is not None and config != self._config:
                # Format and rate are fixed per queue. A voice or rate change
                # already stops playback, so this only retires a finished tail.
                self._retire_output_locked()
            self._stream.submit(chunk)
            if self._feed is None and not chunk.done.is_set():
                self._feed = feed = _Feed(self._stream)
                self._config = config
                self._stream.mark_started()
                threading.Thread(target=self._run_output, args=(feed, config), daemon=True,
                                 name="speech-player-output").start()
        return chunk

    def wait(self, chunk: SpeechChunk, *, cancelled=lambda: False) -> bool:
        """Block until ``chunk`` has been handed to the output.

        Returns False when it was stopped first. Raises ``SpeechPlaybackError``
        when the output failed, so callers never report unplayed audio as done.
        """
        while not chunk.done.wait(MONITOR_SECONDS / 2):
            if cancelled():
                return False
        if chunk.error:
            raise SpeechPlaybackError(chunk.error)
        return not chunk.cancelled

    def stop(self) -> None:
        """Drop queued speech and fade the output out before stopping it."""
        with self._lock:
            self._stream.cancel_all()
            self._retire_output_locked()

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self._stream.cancel_all()
            self._retire_output_locked()

    def _retire_output_locked(self) -> None:
        feed, self._feed = self._feed, None
        if feed is None:
            return
        feed.attached = False
        if feed.output is not None:
            _fade_and_dispose(feed.output)
        # Otherwise the device is still starting; _run_output retires it.

    def _run_output(self, feed: _Feed, config: tuple[PcmFormat, float]) -> None:
        """Start one output, then stop it once idle or fail queued speech if it stalls."""
        output = None
        try:
            output = self._output_factory(*config, feed)
            output.start()
        except Exception as exc:
            print(f"[speech_player] Output failed to start: {exc}", file=sys.stderr)
            if output is not None:
                output.dispose()
            with self._lock:
                if self._feed is feed:
                    self._feed = None
                    self._stream.cancel_all("playback_failed")
            return
        with self._lock:
            feed.output = output
            retired = self._feed is not feed
        if retired:
            # Stopped while the device was starting: fade whatever was primed.
            _fade_and_dispose(output)
            return
        while True:
            time.sleep(MONITOR_SECONDS)
            with self._lock:
                if self._feed is not feed:
                    return
                now = time.monotonic()
                if output.error or now - self._stream.last_render_at > STALL_SECONDS:
                    print(f"[speech_player] Output stalled: {output.error or 'no progress'}", file=sys.stderr)
                    self._feed = None
                    feed.attached = False
                    self._stream.cancel_all("playback_failed")
                    output.dispose()
                    return
                try:
                    hold = bool(self._keep_alive())
                except Exception:
                    hold = False
                idle_limit = IDLE_HOLD_SECONDS if hold else IDLE_STOP_SECONDS
                if not self._stream.pending and now - self._stream.last_audio_at > idle_limit:
                    # Only silence is queued, so stopping needs no fade.
                    self._feed = None
                    feed.attached = False
                    output.dispose()
                    return


def _fade_and_dispose(output) -> None:
    try:
        output.fade_out(FADE_SECONDS)
        output.wait_faded(FADE_WAIT_TIMEOUT)
    finally:
        output.dispose()
