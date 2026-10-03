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
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np

from config import load_config
from custom_voice import ConversionClient, ConversionCancelled, CustomVoiceError, ID_RE, voices_root, support_root, load_profile, load_runtime
from voice_audio_lease import VoiceAudioLease


@dataclass(frozen=True)
class VoiceSelection:
    voice: str
    rate: float
    custom_id: str
    epoch: int
    fingerprint: str = ""

TTS_CONTROL_SOCK = os.environ.get("TTS_CONTROL_SOCK", "/tmp/tts_control.sock")
VOICE_STATE_SOCK = os.environ.get("VOICE_STATE_SOCK", "/tmp/voice_state.sock")
TUTORIAL_TTS_MODE = os.environ.get("RELAY_TUTORIAL_TTS") == "1"


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
    msg = {
        "source": "tts",
        "state": state,
        "tutorial": TUTORIAL_TTS_MODE,
        **kwargs,
    }
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.sendto(json.dumps(msg).encode(), VOICE_STATE_SOCK)
        s.close()
    except (OSError, ConnectionRefusedError):
        pass


def _presentation_fields(
    speech_intent: dict | None,
    *,
    presentation_mode: str | None = None,
    stop_reason: str | None = None,
) -> dict[str, object]:
    if not isinstance(speech_intent, dict):
        return {}
    utterance_id = str(speech_intent.get("utterance_id") or "").strip()
    original_id = str(
        speech_intent.get("original_utterance_id") or utterance_id
    ).strip()
    replay_of = str(speech_intent.get("replay_of") or "").strip() or None
    mode = presentation_mode or (
        "explicit_replay" if replay_of else "new_delivery"
    )
    return {
        "utterance_id": utterance_id or None,
        "original_utterance_id": original_id or None,
        "replay_of": replay_of,
        "presentation_mode": mode,
        "stop_reason": stop_reason,
        "relay_command_seq": speech_intent.get("command_seq"),
        "relay_command_id": speech_intent.get("command_id"),
    }


def publish_waiting_preview(text: str, speech_intent: dict | None = None) -> None:
    preview = str(text or "").strip()
    if preview:
        _notify_state(
            "message_waiting",
            text=preview[:2000],
            **_presentation_fields(speech_intent),
        )


def _resolve_chime(name: str) -> str:
    if os.path.isabs(name):
        return name
    return f"/System/Library/Sounds/{name}.aiff"

# Kokoro voice list (prefix: a=American, b=British; f=female, m=male)
KOKORO_VOICES = ["am_puck", "bm_george", "bf_isabella", "af_sky"]

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

    def __init__(self, input_queue: queue.Queue, *, start_control_socket: bool = True):
        self.input_queue = input_queue
        self._pending_text = ""
        self._pending_display_text = ""
        self._pending_speech_intent: dict | None = None
        self._current_speech_intent: dict | None = None
        self._speech_eligibility = None
        self._speech_observer = None
        self._lock = threading.Lock()
        self._play_request_lock = threading.RLock()
        self._playing = False
        self._paused = False
        self._current_proc: subprocess.Popen | None = None
        self._shutdown = False
        self._last_wav: str | None = None  # Path to last played WAV for replay
        self._last_unheard_text = ""
        self._last_unheard_display_text = ""
        self._last_response_text = ""
        self._last_response_display_text = ""
        self._current_spoken_text = ""
        self._current_display_text = ""
        self._chime_proc: subprocess.Popen | None = None

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
        self._spec_ready_at: float | None = None
        self._spec_done: bool = False
        self._spec_selection = None
        self._spec_token = 0
        # Serializes Kokoro calls so a fallback _speak doesn't race a still-
        # running speculation thread inside the same in-process model.
        self._synth_lock = threading.Lock()
        self._playback_generation = 0
        self._selection_epoch = 0
        self._render_local = threading.local()
        self._render_selections = {}
        self._converter = ConversionClient()
        self._last_wav_profile_id = ""
        self._last_wav_rate = None

        # Read initial config
        cfg = load_config()["tts"]
        self._voice: str = cfg.get("voice", "am_puck")
        self._custom_voice_id = "" if TUTORIAL_TTS_MODE else str(cfg.get("custom_voice_id") or "")
        self._rate: float = float(cfg.get("rate", 1.3))
        self._chime: str = _resolve_chime(cfg.get("chime", "Tink"))
        self._auto_play: bool = False if TUTORIAL_TTS_MODE else cfg.get("auto_play", False)
        self._configured_selection = self._selection()

        # Load Kokoro model
        self._kokoro = None
        self._load_voice()

        # Collector thread — drains input_queue into _pending_text
        self._collector = threading.Thread(target=self._collect_loop, daemon=True)
        self._collector.start()

        # Relay mode gives control-socket ownership to SpeechCoordinator.
        self._control: threading.Thread | None = None
        if start_control_socket:
            self._control = threading.Thread(target=self._control_loop, daemon=True)
            self._control.start()

    def set_speech_callbacks(self, *, eligibility, observer) -> None:
        """Install coordinator-owned eligibility and lifecycle callbacks."""
        self._speech_eligibility = eligibility
        self._speech_observer = observer

    def _speech_is_eligible(self, intent: dict | None) -> bool:
        eligibility = getattr(self, "_speech_eligibility", None)
        if not intent or eligibility is None:
            return True
        try:
            return bool(eligibility(intent))
        except Exception as exc:
            print(f"[tts_worker] Speech eligibility check failed: {exc}", file=sys.stderr)
            return False

    def _observe_speech(self, state: str, intent: dict | None) -> None:
        observer = getattr(self, "_speech_observer", None)
        if not intent or observer is None:
            return
        try:
            observer(state, intent)
        except Exception as exc:
            print(f"[tts_worker] Speech lifecycle callback failed: {exc}", file=sys.stderr)

    def _load_voice(self):
        """Load Kokoro model, downloading if needed."""
        paths = _find_kokoro_model()
        if not paths and not TUTORIAL_TTS_MODE:
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
            previous = getattr(self, "_configured_selection", self._selection())
            self._voice = cfg.get("voice", self._voice)
            self._rate = float(cfg.get("rate", self._rate))
            self._custom_voice_id = "" if TUTORIAL_TTS_MODE else str(cfg.get("custom_voice_id") or "")
            self._chime = _resolve_chime(cfg.get("chime", "Tink"))
            self._auto_play = cfg.get("auto_play", False)
            if previous != self._selection():
                self._selection_epoch = getattr(self, "_selection_epoch", 0) + 1
                self._cancel_speculation()
                self.stop_playback(reason="voice_changed")
            self._configured_selection = self._selection()
            retained_profile = getattr(self, "_last_wav_profile_id", "")
            if retained_profile and not self.custom_profile_exists(retained_profile):
                self.invalidate_custom_profiles({retained_profile})
            print(f"[tts_worker] Config reloaded: voice={self._voice}, rate={self._rate}", file=sys.stderr)
        except Exception as e:
            print(f"[tts_worker] Config reload failed: {e}", file=sys.stderr)

    @property
    def custom_voice_id(self):
        return getattr(self, "_custom_voice_id", "")

    @staticmethod
    def custom_profile_exists(profile_id):
        return bool(isinstance(profile_id, str) and ID_RE.fullmatch(profile_id)
                    and (voices_root() / profile_id).exists())

    def invalidate_custom_profiles(self, profile_ids):
        if getattr(self, "_last_wav_profile_id", "") in profile_ids:
            self._remove_wav(self._last_wav)
            self._last_wav = None
            self._last_wav_profile_id = ""
            self._last_response_text = self._last_response_display_text = ""
        if self.custom_voice_id in profile_ids:
            self._cancel_speculation()
            self.stop_playback(reason="voice_deleted")

    def _selection(self):
        fingerprint = ""
        if self.custom_voice_id:
            try:
                if not ID_RE.fullmatch(self.custom_voice_id):
                    raise CustomVoiceError("invalid_profile_id")
                folder = voices_root() / self.custom_voice_id
                stamps = tuple((p.stat().st_mtime_ns, p.stat().st_size, p.stat().st_ino) for p in (
                    folder / "reference.wav", folder / "manifest.json", support_root() / "custom-voice-runtime.json"))
                cache_key = (self.custom_voice_id, stamps)
                cached = getattr(self, "_profile_fingerprint_cache", None)
                if cached and cached[0] == cache_key:
                    fingerprint = cached[1]
                else:
                    fingerprint = load_profile(self.custom_voice_id).content_hash + ":" + load_runtime().fingerprint
                    self._profile_fingerprint_cache = (cache_key, fingerprint)
            except (CustomVoiceError, OSError):
                fingerprint = "unavailable"
        return VoiceSelection(getattr(self, "_voice", "am_puck"), self._rate,
                              self.custom_voice_id, getattr(self, "_selection_epoch", 0), fingerprint)

    def _synthesize_selected(self, text, selection):
        local = getattr(self, "_render_local", None)
        if local is None:
            self._render_local = local = threading.local()
        local.selection = selection
        try:
            return self._synthesize_to_wav(text)
        finally:
            local.selection = None

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
            self._handle_collected_item(chunk)
            if (
                self._auto_play
                and isinstance(chunk, dict)
                and isinstance(chunk.get("_speech_intent"), dict)
                and not self._playing
            ):
                # Coordinated speech intents are complete, command-scoped
                # responses. They do not need the legacy chunk coalescing delay.
                self.play()

    def _handle_collected_item(self, chunk) -> None:
        if isinstance(chunk, dict) and chunk.get("_tutorial_control"):
            self._handle_command(str(chunk["_tutorial_control"]))
            return
        self._handle_collected_chunk(chunk)

    @staticmethod
    def _queue_texts(chunk) -> tuple[str, str, dict | None]:
        if isinstance(chunk, dict):
            text = str(chunk.get("text") or "").strip()
            display_text = str(chunk.get("display_text") or "").strip()
            intent = chunk.get("_speech_intent")
            return text, display_text, intent if isinstance(intent, dict) else None
        return str(chunk or "").strip(), "", None

    def _handle_collected_chunk(self, chunk):
        # Serialize collection through waiting-pill publication with play().
        # Once the pill is visible, play can always claim this exact pending
        # response; it cannot slip between enqueue and chime startup.
        with self._play_request_lock:
            chunk_text, chunk_display_text, speech_intent = self._queue_texts(chunk)
            if not chunk_text:
                return
            if not self._speech_is_eligible(speech_intent):
                # The coordinator may already have published this preview.
                # Clear only its identity before cancellation advances the queue.
                _notify_state("idle", **_presentation_fields(speech_intent))
                self._observe_speech("cancelled", speech_intent)
                return
            with self._lock:
                was_empty = not self._pending_text.strip()
                if speech_intent is not None:
                    replaced_intent = getattr(self, "_pending_speech_intent", None)
                    self._pending_text = chunk_text
                    self._pending_display_text = chunk_display_text
                    self._pending_speech_intent = speech_intent
                elif self._pending_text:
                    replaced_intent = None
                    self._pending_text += " " + chunk_text
                else:
                    replaced_intent = None
                    self._pending_text = chunk_text

                if chunk_display_text:
                    self._pending_display_text = chunk_display_text
                elif was_empty:
                    self._pending_display_text = ""

                full_text = self._pending_text.strip()
                if full_text:
                    self._last_response_text = full_text
                preview_text = self._pending_display_text.strip() or full_text
                if preview_text:
                    self._last_response_display_text = preview_text
                is_playing = self._playing

            if replaced_intent and replaced_intent != speech_intent:
                self._observe_speech("cancelled", replaced_intent)
            if not full_text:
                return
            self._observe_speech("queued", speech_intent)

            if was_empty and not self._auto_play:
                self._play_chime()

            # Send the full text (capped generously) every time the queued
            # response grows. Deferred-playback overlays should render the latest
            # response body before playback starts, not wait for a later preparing
            # or speaking event to repopulate the pill.
            # An explicit replay starts straight away; skip the waiting
            # preview so the notch doesn't flash "Replay available".
            if not (speech_intent or {}).get("replay_of"):
                publish_waiting_preview(preview_text, speech_intent)

            # Kick off speculative TTS in parallel with the pill so audio is
            # ready by the time the user double-taps Option.
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
        with self._play_request_lock:
            if self._playing:
                return
            with self._lock:
                has_pending = bool(self._pending_text.strip())
            while not has_pending:
                try:
                    queued = self.input_queue.get_nowait()
                except queue.Empty:
                    break
                self._handle_collected_chunk(queued)
                with self._lock:
                    has_pending = bool(self._pending_text.strip())
            with self._lock:
                text = self._pending_text.strip()
                display_text = self._pending_display_text.strip() or text
                speech_intent = getattr(self, "_pending_speech_intent", None)
                self._pending_text = ""
                self._pending_display_text = ""
                self._pending_speech_intent = None
                if text:
                    self._last_unheard_text = ""
                    self._last_unheard_display_text = ""

            if not text:
                return
            if not self._speech_is_eligible(speech_intent):
                # Option has optimistically moved this preview to preparing.
                _notify_state("idle", **_presentation_fields(speech_intent))
                self._observe_speech("cancelled", speech_intent)
                return

            if speech_intent is None:
                self._play_text(text, display_text=display_text)
            else:
                self._play_text(text, display_text=display_text, speech_intent=speech_intent)

    def play_or_replay(self) -> bool:
        """Play pending text, otherwise replay the last completed audio."""
        with self._play_request_lock:
            if self._playing:
                return True
            self.play()
            if self._playing:
                return True
            self.replay()
            return self._playing

    def _play_text(
        self,
        text: str,
        *,
        display_text: str | None = None,
        speech_intent: dict | None = None,
    ):
        chunks = _sentence_chunks(text)
        if not chunks:
            return

        preview_text = str(display_text or "").strip() or text
        self._last_response_text = text
        self._last_response_display_text = preview_text
        self._current_spoken_text = text
        self._current_display_text = preview_text
        generation = self._begin_playback()
        selection = self._selection()
        self._current_playback_rate = selection.rate
        if not hasattr(self, "_render_selections"):
            self._render_selections = {}
        self._render_selections[generation] = selection
        self._current_speech_intent = speech_intent
        _notify_state(
            "preparing",
            text=preview_text[:2000],
            **_presentation_fields(speech_intent),
        )
        self._observe_speech("preparing", {**speech_intent, "custom_voice_id": selection.custom_id}
                             if speech_intent else None)

        t = threading.Thread(
            target=self._speak_chunks,
            args=(chunks, generation, speech_intent),
            daemon=True,
        )
        t.start()

    def _begin_playback(self) -> int:
        self._stop_chime()
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
        self.stop_playback(reason="pause")
        self._paused = True

    def stop_playback(self, *, reason: str = "user_stop"):
        """Stop current audio playback without clearing pending text.
        Used by __TTS_STOP__ to kill audio while preserving queued TTS."""
        with self._play_request_lock:
            self._playback_generation = getattr(self, "_playback_generation", 0) + 1
            if hasattr(self, "_converter"):
                self._converter.close()
            proc = self._current_proc
            if proc and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                with self._lock:
                    if self._current_proc is proc:
                        self._current_proc = None
            self._stop_chime()
            self._playing = False
            self._paused = False
            intent = getattr(self, "_current_speech_intent", None)
            current_text = getattr(self, "_current_spoken_text", "")
            current_display = getattr(self, "_current_display_text", "")
            if current_text:
                self._last_response_text = current_text
                self._last_response_display_text = current_display or current_text
            self._current_speech_intent = None
            self._current_spoken_text = ""
            self._current_display_text = ""
            if intent is not None:
                _notify_state("idle", **_presentation_fields(intent, stop_reason=reason))
            self._observe_speech("cancelled", intent)

    def publish_replay_invalidated(
        self,
        speech_intent: dict | None = None,
        *,
        reason: str,
    ):
        """Clear a retained replay presentation without republishing its text."""
        _notify_state(
            "replay_invalidated",
            **_presentation_fields(
                speech_intent,
                presentation_mode="retained_replay",
                stop_reason=reason,
            ),
        )

    def skip(self):
        """Stop playback AND discard pending text."""
        with self._play_request_lock:
            self.stop_playback()
            with self._lock:
                text = self._pending_text.strip()
                display_text = self._pending_display_text.strip() or text
                pending_intent = getattr(self, "_pending_speech_intent", None)
                self._pending_text = ""
                self._pending_display_text = ""
                self._pending_speech_intent = None
                if text:
                    self._last_unheard_text = text
                    self._last_unheard_display_text = display_text
            self._observe_speech("cancelled", pending_intent)
            self._cancel_speculation()
            _notify_state("idle")

    def replay(self):
        """Replay the last spoken audio."""
        with self._play_request_lock:
            if self._playing:
                return
            with self._lock:
                text = self._pending_text.strip()
                if text:
                    display_text = self._pending_display_text.strip() or text
                    self._pending_text = ""
                    self._pending_display_text = ""
                    self._last_unheard_text = ""
                    self._last_unheard_display_text = ""
                elif self._last_unheard_text:
                    text = self._last_unheard_text
                    display_text = self._last_unheard_display_text.strip() or text
                    self._last_unheard_text = ""
                    self._last_unheard_display_text = ""
                else:
                    display_text = ""

            if text:
                self._play_text(text, display_text=display_text)
                return

            wav = self._last_wav
            retained_profile = getattr(self, "_last_wav_profile_id", "")
            if retained_profile and not self.custom_profile_exists(retained_profile):
                self.invalidate_custom_profiles({retained_profile})
                _notify_state("idle")
                return
            if not wav or not os.path.isfile(wav):
                print("[tts_worker] Nothing to replay", file=sys.stderr)
                return
            if self._last_response_display_text or self._last_response_text:
                self._current_spoken_text = self._last_response_text
                self._current_display_text = (
                    self._last_response_display_text or self._last_response_text
                )
                _notify_state(
                    "preparing",
                    text=(self._last_response_display_text or self._last_response_text)[:2000],
                )
            generation = self._begin_playback()
            self._current_playback_rate = getattr(self, "_last_wav_rate", None) or self._rate
            t = threading.Thread(
                target=self._play_wav,
                args=(wav, generation),
                daemon=True,
            )
            t.start()

    def _play_wav(self, wav_path: str, generation: int):
        """Play a WAV file with afplay."""
        try:
            self._play_wav_blocking(wav_path, generation=generation)
        except Exception as e:
            print(f"[tts_worker] Replay error: {e}", file=sys.stderr)
        finally:
            if self._playback_is_current(generation):
                self._playing = False
                self._paused = False
                _notify_state("idle")
                self._current_spoken_text = ""
                self._current_display_text = ""

    def _play_wav_blocking(self, wav_path: str, *, generation: int | None = None, rate: float | None = None):
        """Play a single WAV file with afplay."""
        if generation is None:
            generation = self._playback_generation
        cmd = ["afplay", wav_path]
        if rate is None:
            rate = getattr(self, "_current_playback_rate", self._rate)
        if rate != 1.0:
            cmd.extend(["-r", str(rate)])
        if not self._playback_is_current(generation):
            return
        with VoiceAudioLease(lambda: not self._playback_is_current(generation)):
            # Re-check under the same lock as stop: cancelled work cannot start afplay.
            with self._play_request_lock:
                if not self._playback_is_current(generation):
                    return
                intent = self._current_speech_intent
                preview = str(getattr(self, "_current_display_text", "") or "").strip()
                proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self._current_proc = proc
                _notify_state("speaking", **({"text": preview[:2000]} if preview else {}),
                              **_presentation_fields(intent))
                self._observe_speech("afplay_started", intent)
            try:
                result = proc.wait()
                if result != 0 and self._playback_is_current(generation):
                    raise CustomVoiceError("playback_failed")
            finally:
                with self._lock:
                    if self._current_proc is proc:
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
            if not self._synth_lock.acquire(timeout=30):
                raise CustomVoiceError("synthesis_timeout")
            try:
                # Synthesize at speed=1.0 to avoid kokoro_onnx int32 truncation bug
                # (newer ONNX exports cast speed to int32, so 1.2 → 1, 1.8 → 1, etc.)
                # Playback rate is applied via afplay -r instead for smooth control.
                selection = getattr(getattr(self, "_render_local", None), "selection", None)
                samples, sample_rate = self._kokoro.create(
                    text, voice=selection.voice if selection else self._voice, speed=1.0, lang="en-us"
                )
            finally:
                self._synth_lock.release()
            if samples is None or len(samples) == 0:
                try:
                    os.remove(wav_path)
                except OSError:
                    pass
                return None
            samples = np.asarray(samples)
            if not np.isfinite(samples).all():
                raise CustomVoiceError("invalid_audio")
            int16_audio = (np.clip(samples, -1, 1) * 32767).astype(np.int16)
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
        selection = self._selection()
        if selection.custom_id:
            # Custom conversion starts only for an eligible rendering attempt.
            # Avoid an unused heavyweight model and parallel clone speculation.
            self._cancel_speculation()
            return
        text = chunks[0]
        with self._spec_cond:
            if (self._spec_text == text and getattr(self, "_spec_selection", None) == selection
                    and (self._spec_wav or not self._spec_done)):
                return
            self._spec_selection = selection
            self._spec_token = getattr(self, "_spec_token", 0) + 1
            token = self._spec_token
            old_wav = self._spec_wav
            self._spec_text = text
            self._spec_wav = None
            self._spec_ready_at = None
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
                    if self._spec_text != text or self._spec_token != token:
                        return
                wav = self._synthesize_selected(text, selection)
            except Exception as e:
                print(f"[tts_worker] Speculation error: {e}", file=sys.stderr)
                wav = None
            with self._spec_cond:
                if self._spec_text != text or self._spec_token != token:
                    # superseded mid-flight — discard
                    if wav:
                        try:
                            os.remove(wav)
                        except OSError:
                            pass
                    return
                self._spec_wav = wav
                self._spec_ready_at = time.time() if wav else None
                self._spec_done = True
                self._spec_cond.notify_all()

        threading.Thread(target=_gen, daemon=True).start()

    def _claim_speculation(
        self,
        text: str,
        timeout: float = 0.0,
    ) -> tuple[str | None, float | None]:
        """Return the speculative WAV and ready time, optionally waiting
        up to `timeout` seconds for an in-flight gen. Caller takes ownership
        of the returned path (the slot is cleared)."""
        deadline = time.monotonic() + max(0.0, timeout)
        with self._spec_cond:
            while True:
                if self._spec_text != text:
                    return None, None
                if self._spec_done:
                    wav = self._spec_wav
                    ready_at = getattr(self, "_spec_ready_at", None)
                    self._spec_wav = None
                    self._spec_ready_at = None
                    self._spec_text = ""
                    self._spec_done = False
                    self._spec_cond.notify_all()
                    return wav, ready_at
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None, None
                self._spec_cond.wait(timeout=remaining)

    def _cancel_speculation(self):
        """Drop any cached or in-flight speculation. In-flight Kokoro work
        cannot be preempted (in-process model), but the result is discarded
        on completion via the supersede check."""
        with self._spec_cond:
            self._spec_token = getattr(self, "_spec_token", 0) + 1
            self._spec_selection = None
            old_wav = self._spec_wav
            self._spec_text = ""
            self._spec_wav = None
            self._spec_ready_at = None
            self._spec_done = False
            self._spec_cond.notify_all()
        if old_wav:
            try:
                os.remove(old_wav)
            except OSError:
                pass

    def _speak_chunks(
        self,
        chunks: list[str],
        generation: int,
        speech_intent: dict | None = None,
    ):
        """Synthesize sentence chunks and play them in order."""
        selection = getattr(self, "_render_selections", {}).get(generation, self._selection())
        if selection.custom_id:
            return self._speak_custom_chunks(chunks, generation, speech_intent, selection)
        if not self._kokoro:
            print(f"[tts_worker] Kokoro not loaded, skipping: {' '.join(chunks)[:80]}", file=sys.stderr)
            self._finish_playback(generation, speech_intent=speech_intent, failed=True)
            return

        played_wavs: list[str] = []
        current_wav: str | None = None
        next_thread: threading.Thread | None = None
        next_result: dict[str, str | None] | None = None
        completed = False
        failed = False

        try:
            if getattr(self, "_spec_selection", None) not in (None, selection):
                self._cancel_speculation()
            current_wav, first_wav_ready_at = self._claim_speculation(chunks[0], timeout=30.0)
            if not current_wav:
                current_wav = self._synthesize_chunk(chunks[0], generation)
                first_wav_ready_at = time.time() if current_wav else None

            if current_wav:
                observed_intent = dict(speech_intent or {})
                if first_wav_ready_at is not None:
                    observed_intent["_event_at"] = first_wav_ready_at
                self._observe_speech("wav_ready", observed_intent)

            for index, _ in enumerate(chunks):
                if (
                    not current_wav
                    or not self._playback_is_current(generation)
                    or not self._speech_is_eligible(speech_intent)
                ):
                    break

                played_wavs.append(current_wav)
                self._set_last_wav(current_wav, preserve_old=index > 0, selection=selection, generation=generation)

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

                if index == 0:
                    self._observe_speech("started", speech_intent)
                self._play_wav_blocking(current_wav, generation=generation, rate=selection.rate)

                if not self._playback_is_current(generation):
                    break

                if next_thread and next_result is not None:
                    deadline = time.monotonic() + 30
                    while next_thread.is_alive() and self._playback_is_current(generation):
                        next_thread.join(timeout=0.05)
                        if time.monotonic() >= deadline:
                            raise CustomVoiceError("synthesis_timeout")
                    current_wav = next_result["wav"]
                    next_thread = None
                    next_result = None
                else:
                    current_wav = None

            completed = (
                self._playback_is_current(generation)
                and len(played_wavs) == len(chunks)
            )
            if (
                not completed
                and self._playback_is_current(generation)
                and self._speech_is_eligible(speech_intent)
            ):
                failed = True
            if completed and len(played_wavs) > 1:
                combined = self._combine_wavs(played_wavs)
                if combined:
                    if not self._set_last_wav(combined, preserve_old=True, selection=selection, generation=generation):
                        self._remove_wav(combined)
                        completed = False
                    for wav in played_wavs:
                        if wav != self._last_wav:
                            self._remove_wav(wav)
                else:
                    keep = self._last_wav
                    for wav in played_wavs:
                        if wav != keep:
                            self._remove_wav(wav)
        except Exception as e:
            print(f"[tts_worker] TTS error: {e}", file=sys.stderr)
            failed = True
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
            self._finish_playback(
                generation,
                speech_intent=speech_intent,
                completed=completed,
                failed=failed,
            )

    def _synthesize_chunk(self, text: str, generation: int) -> str | None:
        try:
            selection = getattr(self, "_render_selections", {}).get(generation, self._selection())
            wav = self._bounded_synthesis(text, selection, lambda: self._playback_is_current(generation))
        except Exception as e:
            print(f"[tts_worker] TTS error: {e}", file=sys.stderr)
            return None
        if wav and not self._playback_is_current(generation):
            self._remove_wav(wav)
            return None
        return wav

    def _speak_custom_chunks(self, chunks, generation, speech_intent, selection):
        paths = []
        completed = failed = False
        fallback = False
        warned = False
        current = lambda: (self._playback_is_current(generation)
                           and self._speech_is_eligible(speech_intent)
                           and selection == self._selection())
        profile = runtime = None
        try:
            try:
                profile = load_profile(selection.custom_id)
                runtime = load_runtime()
            except CustomVoiceError:
                fallback = True
            for index, text in enumerate(chunks):
                if not current():
                    return
                base = self._bounded_synthesis(text, replace(selection, voice="bm_george") if fallback else selection, current)
                if not base:
                    raise CustomVoiceError("synthesis_failed")
                paths.append(base)
                if not current():
                    return
                rendered = base
                if not fallback:
                    fd, name = tempfile.mkstemp(suffix=".wav", prefix="relay-custom-")
                    os.close(fd)
                    paths.append(name)
                    try:
                        self._converter.convert(Path(base), Path(name), profile, runtime,
                                                utterance_id=str((speech_intent or {}).get("utterance_id", generation)),
                                                generation=generation, cancelled=lambda: not current())
                        rendered = name
                    except ConversionCancelled:
                        return
                    except CustomVoiceError:
                        if not current():
                            return
                        fallback = True
                        rendered = self._bounded_synthesis(text, replace(selection, voice="bm_george"), current)
                        if not rendered:
                            raise CustomVoiceError("fallback_failed")
                        paths.append(rendered)
                if not current():
                    return
                if fallback and not warned:
                    # Privacy-safe diagnostic; preserve authoritative response text/identity.
                    _notify_state("custom_voice_fallback", reason="custom_voice_unavailable",
                                  **_presentation_fields(speech_intent))
                    warned = True
                if index == 0:
                    self._observe_speech("wav_ready", speech_intent)
                    self._observe_speech("started", speech_intent)
                self._set_last_wav(rendered, preserve_old=index > 0, selection=selection, generation=generation)
                self._play_wav_blocking(rendered, generation=generation, rate=selection.rate)
                if not current():
                    return
                # Only successfully played chunks enter the retained combined audio.
                if index == 0:
                    played = []
                played.append(rendered)
            if len(played) > 1:
                combined = self._combine_wavs(played)
                if not combined:
                    raise CustomVoiceError("replay_failed")
                if not self._set_last_wav(combined, preserve_old=True, selection=selection, generation=generation):
                    self._remove_wav(combined)
            completed = current()
        except Exception:
            failed = current()
        finally:
            for path in paths:
                if path != self._last_wav:
                    self._remove_wav(path)
            self._finish_playback(generation, speech_intent=speech_intent,
                                  completed=completed, failed=failed)

    def _bounded_synthesis(self, text, selection, current, timeout=30):
        """Kokoro is in-process: abandon a hung call without letting its late WAV escape."""
        condition = threading.Condition()
        result = {"done": False, "wav": None, "abandoned": False}

        def synthesize():
            path = None
            try:
                if current():
                    path = self._synthesize_selected(text, selection)
            except Exception:
                pass
            with condition:
                if result["abandoned"]:
                    self._remove_wav(path)
                else:
                    result.update(done=True, wav=path)
                condition.notify_all()

        threading.Thread(target=synthesize, daemon=True).start()
        deadline = time.monotonic() + timeout
        with condition:
            while not result["done"]:
                if not current() or time.monotonic() >= deadline:
                    result["abandoned"] = True
                    return None
                condition.wait(timeout=0.05)
            if not current():
                self._remove_wav(result["wav"])
                return None
            return result["wav"]

    def _synthesize_next_chunk(
        self,
        text: str,
        generation: int,
        result: dict[str, str | None],
    ):
        path = self._synthesize_chunk(text, generation)
        if path and not self._playback_is_current(generation):
            self._remove_wav(path)
        else:
            result["wav"] = path

    def _finish_playback(
        self,
        generation: int,
        *,
        speech_intent: dict | None = None,
        completed: bool = False,
        failed: bool = False,
    ):
        getattr(self, "_render_selections", {}).pop(generation, None)
        current_text = getattr(self, "_current_spoken_text", "")
        current_display = getattr(self, "_current_display_text", "") or current_text
        if getattr(self, "_playback_generation", 0) == generation:
            self._playing = False
            self._paused = False
            if failed:
                preview = current_display or self._last_response_display_text or self._last_response_text
                _notify_state(
                    "failed",
                    text=preview[:2000],
                    **_presentation_fields(speech_intent),
                )
            else:
                _notify_state("idle", **_presentation_fields(speech_intent))
        elif not self._playing:
            if failed:
                preview = current_display or self._last_response_display_text or self._last_response_text
                _notify_state(
                    "failed",
                    text=preview[:2000],
                    **_presentation_fields(speech_intent),
                )
            else:
                _notify_state("idle", **_presentation_fields(speech_intent))
        intent_was_current = (
            getattr(self, "_current_speech_intent", None) == speech_intent
            and (speech_intent is not None or getattr(self, "_playback_generation", 0) == generation)
        )
        if intent_was_current:
            if current_text:
                self._last_response_text = current_text
                self._last_response_display_text = current_display
            self._current_speech_intent = None
            self._current_spoken_text = ""
            self._current_display_text = ""
            if failed:
                self._observe_speech("failed", speech_intent)
            elif completed:
                self._observe_speech("completed", speech_intent)
            else:
                self._observe_speech("cancelled", speech_intent)

    def _set_last_wav(self, wav_path: str, preserve_old: bool = False,
                      selection: VoiceSelection | None = None, generation: int | None = None):
        with self._play_request_lock:
            if generation is not None and not self._playback_is_current(generation):
                return False
            old_wav = self._last_wav
            self._last_wav = wav_path
            self._last_wav_rate = selection.rate if selection else getattr(self, "_current_playback_rate", self._rate)
            self._last_wav_profile_id = selection.custom_id if selection else self.custom_voice_id
        if old_wav and old_wav != wav_path and not preserve_old:
            self._remove_wav(old_wav)
        return True

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
        self._stop_chime()
        try:
            self._chime_proc = subprocess.Popen(
                ["afplay", self._chime],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except FileNotFoundError:
            pass

    def _stop_chime(self):
        proc = getattr(self, "_chime_proc", None)
        self._chime_proc = None
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

    def shutdown(self):
        self._shutdown = True
        self.skip()
        if hasattr(self, "_converter"):
            self._converter.close()
        self._remove_wav(self._last_wav)
        self._last_wav = None


def _handle_standalone_line(worker: TTSWorker, q: queue.Queue, text: str) -> None:
    if text == "__PLAY__":
        q.put({"_tutorial_control": "play"})
    elif text == "__REPLAY__":
        q.put({"_tutorial_control": "replay"})
    elif text == "__CANCEL__":
        q.put({"_tutorial_control": "skip"})
    elif text:
        q.put(text)


def main():
    """Standalone mode -- read lines from stdin, queue for TTS."""
    q: queue.Queue = queue.Queue()
    worker = TTSWorker(q)
    print(f"[tts_worker] Voice: {worker._voice}, Rate: {worker._rate}", file=sys.stderr)
    print(f"[tts_worker] Control: {TTS_CONTROL_SOCK}", file=sys.stderr)

    try:
        for line in sys.stdin:
            _handle_standalone_line(worker, q, line.strip())
    except KeyboardInterrupt:
        pass
    finally:
        worker.shutdown()


if __name__ == "__main__":
    main()
