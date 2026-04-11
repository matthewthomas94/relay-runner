#!/usr/bin/env python3
"""TTS playback worker — queues natural language chunks, plays via Kokoro-onnx."""

from __future__ import annotations

import os
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import wave

import numpy as np

from config import load_config

TTS_CONTROL_SOCK = os.environ.get("TTS_CONTROL_SOCK", "/tmp/tts_control.sock")


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

        # Read initial config
        cfg = load_config()["tts"]
        self._voice: str = cfg.get("voice", "af_bella")
        self._rate: float = float(cfg.get("rate", 1.0))
        self._chime: str = _resolve_chime(cfg.get("chime", "Tink"))
        self._auto_play: bool = cfg.get("auto_play", True)

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
            self._auto_play = cfg.get("auto_play", True)
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
            with self._lock:
                was_empty = not self._pending_text.strip()
                if self._pending_text:
                    self._pending_text += " " + chunk
                else:
                    self._pending_text = chunk

                if was_empty and self._pending_text.strip():
                    self._play_chime()

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

        if not text:
            self.replay()
            return

        self._playing = True
        self._paused = False

        t = threading.Thread(target=self._speak, args=(text,), daemon=True)
        t.start()

    def pause(self):
        self._paused = True
        proc = self._current_proc
        if proc and proc.poll() is None:
            proc.terminate()

    def skip(self):
        proc = self._current_proc
        if proc and proc.poll() is None:
            proc.terminate()
        with self._lock:
            self._pending_text = ""
        self._playing = False
        self._paused = False

    def replay(self):
        """Replay the last spoken audio."""
        wav = self._last_wav
        if not wav or not os.path.isfile(wav):
            print("[tts_worker] Nothing to replay", file=sys.stderr)
            return
        self._playing = True
        self._paused = False
        t = threading.Thread(target=self._play_wav, args=(wav,), daemon=True)
        t.start()

    def _play_wav(self, wav_path: str):
        """Play a WAV file with afplay."""
        try:
            cmd = ["afplay", wav_path]
            if self._rate != 1.0:
                cmd.extend(["-r", str(self._rate)])
            self._current_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self._current_proc.wait()
        except Exception as e:
            print(f"[tts_worker] Replay error: {e}", file=sys.stderr)
        finally:
            self._playing = False
            self._current_proc = None

    def _speak(self, text: str):
        """Synthesize and play speech using Kokoro."""
        if not self._kokoro:
            print(f"[tts_worker] Kokoro not loaded, skipping: {text[:80]}", file=sys.stderr)
            self._playing = False
            return

        wav_fd, wav_path = tempfile.mkstemp(suffix=".wav")
        os.close(wav_fd)

        try:
            # Synthesize at speed=1.0 to avoid kokoro_onnx int32 truncation bug
            # (newer ONNX exports cast speed to int32, so 1.2 → 1, 1.8 → 1, etc.)
            # Playback rate is applied via afplay -r instead for smooth control.
            samples, sample_rate = self._kokoro.create(
                text, voice=self._voice, speed=1.0, lang="en-us"
            )

            if samples is None or len(samples) == 0:
                return

            # Convert float32 [-1,1] to int16
            int16_audio = (np.asarray(samples) * 32767).astype(np.int16)

            # Write WAV file
            with wave.open(wav_path, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)  # 16-bit
                wf.setframerate(sample_rate)
                wf.writeframes(int16_audio.tobytes())

            # Keep previous WAV for replay, clean up the one before
            old_wav = self._last_wav
            self._last_wav = wav_path

            if old_wav and old_wav != wav_path:
                try:
                    os.remove(old_wav)
                except OSError:
                    pass

            # Play with afplay, using -r for playback rate (1.0 = normal, 2.0 = 2x)
            cmd = ["afplay", wav_path]
            if self._rate != 1.0:
                cmd.extend(["-r", str(self._rate)])
            self._current_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self._current_proc.wait()
        except Exception as e:
            print(f"[tts_worker] TTS error: {e}", file=sys.stderr)
        finally:
            self._playing = False
            self._current_proc = None

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
