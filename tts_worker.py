#!/usr/bin/env python3
"""TTS playback worker — queues natural language chunks, plays on demand."""

import os
import queue
import socket
import subprocess
import sys
import threading

TTS_ENGINE = os.environ.get("TTS_ENGINE", "say")
TTS_VOICE = os.environ.get("TTS_VOICE", "Samantha")
TTS_RATE = os.environ.get("TTS_RATE", "185")
TTS_CHIME = os.environ.get("TTS_CHIME", "/System/Library/Sounds/Tink.aiff")
TTS_CONTROL_SOCK = os.environ.get("TTS_CONTROL_SOCK", "/tmp/tts_control.sock")


class TTSWorker:
    """Manages a queue of text chunks and plays them via TTS on command."""

    def __init__(self, input_queue: queue.Queue):
        self.input_queue = input_queue
        self._pending_text = ""
        self._lock = threading.Lock()
        self._playing = False
        self._paused = False
        self._current_proc = None
        self._shutdown = False
        self._had_empty_queue = True  # Start as empty

        # Collector thread — drains input_queue into _pending_text
        self._collector = threading.Thread(target=self._collect_loop, daemon=True)
        self._collector.start()

        # Control socket listener
        self._control = threading.Thread(target=self._control_loop, daemon=True)
        self._control.start()

    def _collect_loop(self):
        """Continuously drain input_queue, concatenating into pending message."""
        while not self._shutdown:
            try:
                chunk = self.input_queue.get(timeout=0.2)
            except queue.Empty:
                continue

            with self._lock:
                was_empty = not self._pending_text.strip()
                if self._pending_text:
                    self._pending_text += " " + chunk
                else:
                    self._pending_text = chunk

                # Chime when queue transitions from empty to non-empty
                if was_empty and self._pending_text.strip():
                    self._play_chime()

    def _control_loop(self):
        """Listen on Unix socket for play/pause/skip commands."""
        # Remove stale socket
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
        """Process a control command."""
        if cmd == "play":
            self.play()
        elif cmd == "pause":
            self.pause()
        elif cmd == "skip":
            self.skip()
        elif cmd == "toggle":
            if self._playing and not self._paused:
                self.pause()
            else:
                self.play()

    def play(self):
        """Play the current pending message."""
        with self._lock:
            text = self._pending_text.strip()
            self._pending_text = ""

        if not text:
            return

        self._playing = True
        self._paused = False

        # Speak in a thread so control socket stays responsive
        t = threading.Thread(target=self._speak, args=(text,), daemon=True)
        t.start()

    def pause(self):
        """Pause current playback."""
        self._paused = True
        proc = self._current_proc
        if proc and proc.poll() is None:
            proc.terminate()

    def skip(self):
        """Skip current playback and clear pending text."""
        proc = self._current_proc
        if proc and proc.poll() is None:
            proc.terminate()
        with self._lock:
            self._pending_text = ""
        self._playing = False
        self._paused = False

    def _speak(self, text: str):
        """Run TTS engine to speak the text."""
        try:
            if TTS_ENGINE == "say":
                self._current_proc = subprocess.Popen(
                    ["say", "-v", TTS_VOICE, "-r", TTS_RATE, text],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                self._current_proc.wait()
            elif TTS_ENGINE == "piper":
                self._current_proc = subprocess.Popen(
                    ["piper", "--output_raw"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                # Pipe text to piper, pipe audio to aplay
                audio_data, _ = self._current_proc.communicate(input=text.encode())
                if audio_data:
                    aplay = subprocess.Popen(
                        ["aplay", "-r", "22050", "-f", "S16_LE", "-c", "1"],
                        stdin=subprocess.PIPE,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    aplay.communicate(input=audio_data)
            elif TTS_ENGINE == "none":
                # Silent mode — just print what would be spoken
                print(f"\n[tts] {text}", file=sys.stderr)
        except FileNotFoundError:
            print(f"[tts_worker] TTS engine '{TTS_ENGINE}' not found", file=sys.stderr)
        except Exception as e:
            print(f"[tts_worker] TTS error: {e}", file=sys.stderr)
        finally:
            self._playing = False
            self._current_proc = None

    def _play_chime(self):
        """Play notification chime."""
        if not os.path.exists(TTS_CHIME):
            return
        try:
            subprocess.Popen(
                ["afplay", TTS_CHIME],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except FileNotFoundError:
            # afplay is macOS-only; on Linux try paplay or aplay
            for player in ["paplay", "aplay"]:
                try:
                    subprocess.Popen(
                        [player, TTS_CHIME],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    break
                except FileNotFoundError:
                    continue

    def shutdown(self):
        """Stop the worker."""
        self._shutdown = True
        self.skip()


def main():
    """Standalone mode — read lines from stdin, queue for TTS."""
    q = queue.Queue()
    worker = TTSWorker(q)
    print(f"[tts_worker] Listening on {TTS_CONTROL_SOCK}", file=sys.stderr)
    print(f"[tts_worker] Engine: {TTS_ENGINE}, Voice: {TTS_VOICE}, Rate: {TTS_RATE}", file=sys.stderr)

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
