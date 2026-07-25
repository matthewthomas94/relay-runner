#!/usr/bin/env python3
"""TTS playback worker — queues natural language chunks, plays via Kokoro-onnx."""

from __future__ import annotations

import json
import os
import queue
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import wave

import numpy as np

from config import load_config

TTS_CONTROL_SOCK = os.environ.get("TTS_CONTROL_SOCK", "/tmp/tts_control.sock")
VOICE_STATE_SOCK = "/tmp/voice_state.sock"


_SENTENCE_END_RE = re.compile(r"[.!?]+[\"')\]]*(?=\s+|$)")


def _sentence_chunks(text: str) -> list[str]:
    """Split text into sentence-sized chunks while preserving all text."""
    compact = re.sub(r"\s+", " ", text.strip())
    if not compact:
        return []

    chunks: list[str] = []
    start = 0
    for match in _SENTENCE_END_RE.finditer(compact):
        end = match.end()
        chunk = compact[start:end].strip()
        if chunk:
            chunks.append(chunk)
        start = end

    tail = compact[start:].strip()
    if tail:
        chunks.append(tail)
    return chunks


def _notify_state(state: str, **kwargs):
    """Send a state update to the overlay app via Unix datagram socket.
    Silently fails if the socket doesn't exist (overlay not running)."""
    msg = {"source": "tts", "state": state, **kwargs}
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.sendto(json.dumps(msg).encode(), VOICE_STATE_SOCK)
        s.close()
    except (OSError, ConnectionRefusedError):
        pass


def publish_waiting_preview(text: str) -> None:
    preview = str(text or "").strip()
    if preview:
        _notify_state("message_waiting", text=preview[:2000])


def _resolve_chime(name: str) -> str:
    if os.path.isabs(name):
        return name
    return f"/System/Library/Sounds/{name}.aiff"

# Kokoro voice list (prefix: a=American, b=British; f=female, m=male)
KOKORO_VOICES = [
    "af_bella", "af_sarah", "af_nicole", "af_sky", "af_heart",
    "am_adam", "am_michael",
    "bf_emma", "bf_isabella",
    "bm_george", "bm_lewis",
]

# Search paths for Kokoro model files
_bundled_kokoro = os.path.join(os.environ.get("VOICE_MODELS_DIR", ""), "kokoro")
KOKORO_MODEL_DIRS = [
    d for d in [
        _bundled_kokoro if os.environ.get("VOICE_MODELS_DIR") else None,
        os.path.expanduser("~/.local/share/kokoro"),
    ] if d
]

KOKORO_MODEL_FILE = "kokoro-v1.0.onnx"
KOKORO_VOICES_FILE = "voices-v1.0.bin"


def _find_kokoro_model() -> tuple[str, str] | None:
    """Find kokoro model and voices files in search paths."""
    for d in KOKORO_MODEL_DIRS:
        model = os.path.join(d, KOKORO_MODEL_FILE)
        voices = os.path.join(d, KOKORO_VOICES_FILE)
        if os.path.isfile(model) and os.path.isfile(voices):
            return model, voices
    return None


def _download_kokoro_model() -> tuple[str, str] | None:
    """Download Kokoro model files from HuggingFace."""
    download_dir = os.path.expanduser("~/.local/share/kokoro")
    os.makedirs(download_dir, exist_ok=True)

    try:
        from huggingface_hub import hf_hub_download
        print("[tts_worker] Downloading Kokoro model...", file=sys.stderr)

        for filename in [KOKORO_MODEL_FILE, KOKORO_VOICES_FILE]:
            hf_hub_download(
                repo_id="fastrtc/kokoro-onnx",
                filename=filename,
                local_dir=download_dir,
                local_dir_use_symlinks=False,
            )

        model = os.path.join(download_dir, KOKORO_MODEL_FILE)
        voices = os.path.join(download_dir, KOKORO_VOICES_FILE)
        if os.path.isfile(model) and os.path.isfile(voices):
            print(f"[tts_worker] Model downloaded: {download_dir}", file=sys.stderr)
            return model, voices
    except Exception as e:
        print(f"[tts_worker] Failed to download model: {e}", file=sys.stderr)
    return None


class TTSWorker:
    """Manages a queue of text chunks and plays them via Kokoro TTS."""

    def __init__(self, input_queue: queue.Queue):
        self.input_queue = input_queue
        self._pending_text = ""
        self._lock = threading.Lock()
        self._playing = False
        self._paused = False
        self._current_proc: subprocess.Popen | None = None
        self._shutdown = False
        self._last_wav: str | None = None  # Path to last played WAV for replay
        self._last_unheard_text = ""
        self._last_response_text = ""

        # Speculative TTS — generation runs in parallel with the pill so the
        # first sentence chunk is already on disk by the time the user
        # double-taps Option to play.
        # _spec_text is the text the slot currently belongs to; _spec_wav is
        # the synthesized file once ready; _spec_done flips to True when the
        # generator finishes (success or failure). Mutating any of these or
        # waiting for them goes through _spec_cond.
        self._spec_lock = threading.Lock()
        self._spec_cond = threading.Condition(self._spec_lock)
        self._spec_text: str = ""
        self._spec_wav: str | None = None
        self._spec_done: bool = False
        # Serializes Kokoro calls so a fallback _speak doesn't race a still-
        # running speculation thread inside the same in-process model.
        self._synth_lock = threading.Lock()
        self._playback_generation = 0

        # Read initial config
        cfg = load_config()["tts"]
        self._voice: str = cfg.get("voice", "af_bella")
        self._rate: float = float(cfg.get("rate", 1.0))
        self._chime: str = _resolve_chime(cfg.get("chime", "Tink"))
        self._auto_play: bool = cfg.get("auto_play", False)

        # Load Kokoro model
        self._kokoro = None
        self._load_voice()

        # Collector thread — drains input_queue into _pending_text
        self._collector = threading.Thread(target=self._collect_loop, daemon=True)
        self._collector.start()

        # Control socket listener
        self._control = threading.Thread(target=self._control_loop, daemon=True)
        self._control.start()

    def _load_voice(self):
        """Load Kokoro model, downloading if needed."""
        paths = _find_kokoro_model()
        if not paths:
            paths = _download_kokoro_model()

        if not paths:
            print("[tts_worker] Warning: could not find or download Kokoro model", file=sys.stderr)
            return

        try:
            from kokoro_onnx import Kokoro
            model_path, voices_path = paths
            self._kokoro = Kokoro(model_path, voices_path)
            print(f"[tts_worker] Loaded Kokoro model: {model_path}", file=sys.stderr)
        except Exception as e:
            print(f"[tts_worker] Failed to load Kokoro: {e}", file=sys.stderr)

    def reload_config(self):
        """Re-read config.toml and update voice, chime, rate, auto_play."""
        try:
            cfg = load_config()["tts"]
            self._voice = cfg.get("voice", self._voice)
            self._rate = float(cfg.get("rate", self._rate))
            self._chime = _resolve_chime(cfg.get("chime", "Tink"))
            self._auto_play = cfg.get("auto_play", False)
            print(f"[tts_worker] Config reloaded: voice={self._voice}, rate={self._rate}", file=sys.stderr)
        except Exception as e:
            print(f"[tts_worker] Config reload failed: {e}", file=sys.stderr)

    def _collect_loop(self):
        """Continuously drain input_queue. Auto-plays or queues based on config."""
        idle_ticks = 0
        while not self._shutdown:
            try:
                chunk = self.input_queue.get(timeout=0.2)
            except queue.Empty:
                idle_ticks += 1
                if self._auto_play:
                    with self._lock:
                        has_text = bool(self._pending_text.strip())
                    if has_text and idle_ticks >= 5 and not self._playing:
                        self.play()
                continue

            idle_ticks = 0
            self._handle_collected_chunk(chunk)

    def _handle_collected_chunk(self, chunk: str):
        with self._lock:
            was_empty = not self._pending_text.strip()
            if self._pending_text:
                self._pending_text += " " + chunk
            else:
                self._pending_text = chunk

            full_text = self._pending_text.strip()
            if full_text:
                self._last_response_text = full_text
            is_playing = self._playing

        if not full_text:
            return

        if was_empty:
            self._play_chime()

        # Send the full text (capped generously) every time the queued
        # response grows. Deferred-playback overlays should render the latest
        # response body before playback starts, not wait for a later preparing
        # or speaking event to repopulate the pill.
        publish_waiting_preview(full_text)

        # Kick off speculative TTS in parallel with the pill so audio is
        # ready by the time the user double-taps Option. Outside the main
        # lock — speculation has its own lock and Kokoro can take seconds.
        if not is_playing:
            self._start_speculation(full_text)

    def _control_loop(self):
        """Listen on Unix socket for play/pause/skip commands."""
        try:
            os.unlink(TTS_CONTROL_SOCK)
        except OSError:
            pass

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        sock.bind(TTS_CONTROL_SOCK)
        sock.settimeout(0.5)

        try:
            while not self._shutdown:
                try:
                    data, _ = sock.recvfrom(256)
                    cmd = data.decode("utf-8", errors="replace").strip().lower()
                    self._handle_command(cmd)
                except socket.timeout:
                    continue
        finally:
            sock.close()
            try:
                os.unlink(TTS_CONTROL_SOCK)
            except OSError:
                pass

    def _handle_command(self, cmd: str):
        if cmd == "play":
            self.play()
        elif cmd == "pause":
            self.pause()
        elif cmd == "skip":
            self.skip()
        elif cmd == "replay":
            self.replay()
        elif cmd == "toggle":
            if self._playing and not self._paused:
                self.pause()
            else:
                self.play()

    def play(self):
        with self._lock:
            text = self._pending_text.strip()
            self._pending_text = ""
            if text:
                self._last_unheard_text = ""

        if not text:
            self.replay()
            return

        self._play_text(text)

    def _play_text(self, text: str):
        chunks = _sentence_chunks(text)
        if not chunks:
            return

        self._last_response_text = text
        generation = self._begin_playback()
        _notify_state("preparing", text=text[:2000])

        t = threading.Thread(
            target=self._speak_chunks,
            args=(chunks, generation),
            daemon=True,
        )
        t.start()

    def _begin_playback(self) -> int:
        with self._lock:
            self._playback_generation = getattr(self, "_playback_generation", 0) + 1
            self._playing = True
            self._paused = False
            return self._playback_generation

    def _playback_is_current(self, generation: int) -> bool:
        return (
            getattr(self, "_playback_generation", 0) == generation
            and self._playing
        )

    def pause(self):
        self._playback_generation = getattr(self, "_playback_generation", 0) + 1
        self._paused = True
        proc = self._current_proc
        if proc and proc.poll() is None:
            proc.terminate()
        self._playing = False

    def stop_playback(self):
        """Stop current audio playback without clearing pending text.
        Used by __TTS_STOP__ to kill audio while preserving queued TTS."""
        self._playback_generation = getattr(self, "_playback_generation", 0) + 1
        proc = self._current_proc
        if proc and proc.poll() is None:
            proc.terminate()
        self._playing = False
        self._paused = False

    def skip(self):
        """Stop playback AND discard pending text."""
        self.stop_playback()
        with self._lock:
            text = self._pending_text.strip()
            self._pending_text = ""
            if text:
                self._last_unheard_text = text
        self._cancel_speculation()
        _notify_state("idle")

    def replay(self):
        """Replay the last spoken audio."""
        with self._lock:
            text = self._pending_text.strip()
            if text:
                self._pending_text = ""
                self._last_unheard_text = ""
            elif self._last_unheard_text:
                text = self._last_unheard_text
                self._last_unheard_text = ""

        if text:
            self._play_text(text)
            return

        wav = self._last_wav
        if not wav or not os.path.isfile(wav):
            print("[tts_worker] Nothing to replay", file=sys.stderr)
            return
        if self._last_response_text:
            _notify_state("preparing", text=self._last_response_text[:2000])
        self._playing = True
        self._paused = False
        t = threading.Thread(target=self._play_wav, args=(wav,), daemon=True)
        t.start()

    def _play_wav(self, wav_path: str):
        """Play a WAV file with afplay."""
        try:
            self._play_wav_blocking(wav_path)
        except Exception as e:
            print(f"[tts_worker] Replay error: {e}", file=sys.stderr)
        finally:
            self._playing = False
            self._current_proc = None
            _notify_state("idle")

    def _play_wav_blocking(self, wav_path: str):
        """Play a single WAV file with afplay."""
        _notify_state("speaking")
        cmd = ["afplay", wav_path]
        if self._rate != 1.0:
            cmd.extend(["-r", str(self._rate)])
        self._current_proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            self._current_proc.wait()
        finally:
            self._current_proc = None

    def _synthesize_to_wav(self, text: str) -> str | None:
        """Render `text` to a fresh WAV via Kokoro, return its path or None on failure.
        Serialized via _synth_lock so a fallback _speak doesn't fight a still-running
        speculation thread inside the in-process model."""
        if not self._kokoro:
            return None
        wav_fd, wav_path = tempfile.mkstemp(suffix=".wav")
        os.close(wav_fd)
        try:
            with self._synth_lock:
                # Synthesize at speed=1.0 to avoid kokoro_onnx int32 truncation bug
                # (newer ONNX exports cast speed to int32, so 1.2 → 1, 1.8 → 1, etc.)
                # Playback rate is applied via afplay -r instead for smooth control.
                samples, sample_rate = self._kokoro.create(
                    text, voice=self._voice, speed=1.0, lang="en-us"
                )
            if samples is None or len(samples) == 0:
                try:
                    os.remove(wav_path)
                except OSError:
                    pass
                return None
            int16_audio = (np.asarray(samples) * 32767).astype(np.int16)
            with wave.open(wav_path, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)  # 16-bit
                wf.setframerate(sample_rate)
                wf.writeframes(int16_audio.tobytes())
            return wav_path
        except Exception:
            try:
                os.remove(wav_path)
            except OSError:
                pass
            raise

    def _start_speculation(self, text: str):
        """Begin (or restart) speculative TTS gen for `text` in a daemon thread.
        No-op when the slot is already speculating on the same text or has it
        cached. Newer texts supersede older ones; the older thread's output is
        discarded when it returns."""
        chunks = _sentence_chunks(text)
        if not self._kokoro or not chunks:
            return
        text = chunks[0]
        with self._spec_cond:
            if self._spec_text == text and (self._spec_wav or not self._spec_done):
                return
            old_wav = self._spec_wav
            self._spec_text = text
            self._spec_wav = None
            self._spec_done = False
            self._spec_cond.notify_all()
        if old_wav:
            try:
                os.remove(old_wav)
            except OSError:
                pass

        def _gen():
            wav: str | None = None
            try:
                # Skip the (potentially expensive) Kokoro call if our request
                # has already been superseded by a newer one.
                with self._spec_cond:
                    if self._spec_text != text:
                        return
                wav = self._synthesize_to_wav(text)
            except Exception as e:
                print(f"[tts_worker] Speculation error: {e}", file=sys.stderr)
                wav = None
            with self._spec_cond:
                if self._spec_text != text:
                    # superseded mid-flight — discard
                    if wav:
                        try:
                            os.remove(wav)
                        except OSError:
                            pass
                    return
                self._spec_wav = wav
                self._spec_done = True
                self._spec_cond.notify_all()

        threading.Thread(target=_gen, daemon=True).start()

    def _claim_speculation(self, text: str, timeout: float = 0.0) -> str | None:
        """Return the speculative WAV for `text` if ready, optionally waiting
        up to `timeout` seconds for an in-flight gen. Caller takes ownership
        of the returned path (the slot is cleared)."""
        deadline = time.monotonic() + max(0.0, timeout)
        with self._spec_cond:
            while True:
                if self._spec_text != text:
                    return None
                if self._spec_done:
                    wav = self._spec_wav
                    self._spec_wav = None
                    self._spec_text = ""
                    self._spec_done = False
                    self._spec_cond.notify_all()
                    return wav
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self._spec_cond.wait(timeout=remaining)

    def _cancel_speculation(self):
        """Drop any cached or in-flight speculation. In-flight Kokoro work
        cannot be preempted (in-process model), but the result is discarded
        on completion via the supersede check."""
        with self._spec_cond:
            old_wav = self._spec_wav
            self._spec_text = ""
            self._spec_wav = None
            self._spec_done = False
            self._spec_cond.notify_all()
        if old_wav:
            try:
                os.remove(old_wav)
            except OSError:
                pass

    def _speak_chunks(self, chunks: list[str], generation: int):
        """Synthesize sentence chunks and play them in order."""
        if not self._kokoro:
            print(f"[tts_worker] Kokoro not loaded, skipping: {' '.join(chunks)[:80]}", file=sys.stderr)
            self._finish_playback(generation)
            return

        played_wavs: list[str] = []
        current_wav: str | None = None
        next_thread: threading.Thread | None = None
        next_result: dict[str, str | None] | None = None
        completed = False

        try:
            current_wav = self._claim_speculation(chunks[0], timeout=30.0)
            if not current_wav:
                current_wav = self._synthesize_chunk(chunks[0], generation)

            for index, _ in enumerate(chunks):
                if not current_wav or not self._playback_is_current(generation):
                    break

                played_wavs.append(current_wav)
                self._set_last_wav(current_wav, preserve_old=index > 0)

                next_index = index + 1
                if next_index < len(chunks):
                    next_result = {"wav": None}
                    next_thread = threading.Thread(
                        target=self._synthesize_next_chunk,
                        args=(chunks[next_index], generation, next_result),
                        daemon=True,
                    )
                    next_thread.start()
                else:
                    next_result = None
                    next_thread = None

                self._play_wav_blocking(current_wav)

                if not self._playback_is_current(generation):
                    break

                if next_thread and next_result is not None:
                    next_thread.join()
                    current_wav = next_result["wav"]
                    next_thread = None
                    next_result = None
                else:
                    current_wav = None

            completed = (
                self._playback_is_current(generation)
                and len(played_wavs) == len(chunks)
            )
            if completed and len(played_wavs) > 1:
                combined = self._combine_wavs(played_wavs)
                if combined:
                    self._last_wav = combined
                    for wav in played_wavs:
                        self._remove_wav(wav)
                else:
                    keep = self._last_wav
                    for wav in played_wavs:
                        if wav != keep:
                            self._remove_wav(wav)
        except Exception as e:
            print(f"[tts_worker] TTS error: {e}", file=sys.stderr)
        finally:
            if next_result and next_result.get("wav"):
                self._remove_wav(next_result["wav"])
            if current_wav and current_wav not in played_wavs and current_wav != self._last_wav:
                self._remove_wav(current_wav)
            if not completed:
                keep = self._last_wav
                for wav in played_wavs:
                    if wav != keep:
                        self._remove_wav(wav)
            self._finish_playback(generation)

    def _synthesize_chunk(self, text: str, generation: int) -> str | None:
        try:
            wav = self._synthesize_to_wav(text)
        except Exception as e:
            print(f"[tts_worker] TTS error: {e}", file=sys.stderr)
            return None
        if wav and not self._playback_is_current(generation):
            self._remove_wav(wav)
            return None
        return wav

    def _synthesize_next_chunk(
        self,
        text: str,
        generation: int,
        result: dict[str, str | None],
    ):
        result["wav"] = self._synthesize_chunk(text, generation)

    def _finish_playback(self, generation: int):
        if getattr(self, "_playback_generation", 0) == generation:
            self._playing = False
            self._paused = False
            _notify_state("idle")
        elif not self._playing:
            _notify_state("idle")
        self._current_proc = None

    def _set_last_wav(self, wav_path: str, preserve_old: bool = False):
        old_wav = self._last_wav
        self._last_wav = wav_path
        if old_wav and old_wav != wav_path and not preserve_old:
            self._remove_wav(old_wav)

    def _combine_wavs(self, wav_paths: list[str]) -> str | None:
        if not wav_paths:
            return None
        wav_fd, wav_path = tempfile.mkstemp(suffix=".wav")
        os.close(wav_fd)
        try:
            with wave.open(wav_paths[0], "rb") as first:
                params = (
                    first.getnchannels(),
                    first.getsampwidth(),
                    first.getframerate(),
                    first.getcomptype(),
                    first.getcompname(),
                )
                frames = first.readframes(first.getnframes())

            with wave.open(wav_path, "wb") as out:
                out.setnchannels(params[0])
                out.setsampwidth(params[1])
                out.setframerate(params[2])
                out.setcomptype(params[3], params[4])
                out.writeframes(frames)
                for path in wav_paths[1:]:
                    with wave.open(path, "rb") as source:
                        source_params = (
                            source.getnchannels(),
                            source.getsampwidth(),
                            source.getframerate(),
                            source.getcomptype(),
                            source.getcompname(),
                        )
                        if source_params != params:
                            self._remove_wav(wav_path)
                            return None
                        out.writeframes(source.readframes(source.getnframes()))
            return wav_path
        except Exception as e:
            print(f"[tts_worker] WAV combine error: {e}", file=sys.stderr)
            self._remove_wav(wav_path)
            return None

    def _remove_wav(self, wav_path: str | None):
        if not wav_path:
            return
        try:
            os.remove(wav_path)
        except OSError:
            pass

    def _play_chime(self):
        if not os.path.exists(self._chime):
            return
        try:
            subprocess.Popen(
                ["afplay", self._chime],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except FileNotFoundError:
            pass

    def shutdown(self):
        self._shutdown = True
        self.skip()


def main():
    """Standalone mode -- read lines from stdin, queue for TTS."""
    q: queue.Queue = queue.Queue()
    worker = TTSWorker(q)
    print(f"[tts_worker] Voice: {worker._voice}, Rate: {worker._rate}", file=sys.stderr)
    print(f"[tts_worker] Control: {TTS_CONTROL_SOCK}", file=sys.stderr)

    try:
        for line in sys.stdin:
            text = line.strip()
            if text:
                q.put(text)
    except KeyboardInterrupt:
        pass
    finally:
        worker.shutdown()


if __name__ == "__main__":
    main()
