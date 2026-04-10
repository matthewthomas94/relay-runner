#!/usr/bin/env python3
"""Voice bridge — connects voice FIFO to Claude Code via JSON API, feeds TTS."""

from __future__ import annotations

import json
import os
import queue
import re
import select
import shutil
import subprocess
import sys
import threading

from config import load_config
from tts_worker import TTSWorker

VOICE_FIFO = os.environ.get("VOICE_FIFO", "/tmp/voice_in.fifo")


def open_fifo(path: str) -> int | None:
    if not os.path.exists(path):
        try:
            os.mkfifo(path)
        except OSError as e:
            print(f"[voice_bridge] Could not create FIFO {path}: {e}", file=sys.stderr)
            return None
    try:
        return os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError as e:
        print(f"[voice_bridge] Could not open FIFO {path}: {e}", file=sys.stderr)
        return None


class VoiceBridge:
    def __init__(self, claude_bin: str, tts_queue: queue.Queue):
        self.claude_bin = claude_bin
        self.tts_queue = tts_queue
        self.session_id: str | None = None
        self._claude_proc: subprocess.Popen | None = None
        self._lock = threading.Lock()

    def interrupt(self):
        """Kill any running Claude process and stop TTS."""
        with self._lock:
            proc = self._claude_proc
            if proc and proc.poll() is None:
                proc.kill()
                proc.wait()
                self._claude_proc = None
                print("\r\033[2K\033[1;33m  interrupted\033[0m")
                sys.stdout.flush()

    def send(self, text: str):
        """Send a message to Claude, display + speak the response."""
        # Kill any in-progress request first
        self.interrupt()

        # Display prompt
        print(f"\n\033[1;36m❯ {text}\033[0m")
        print("\033[2m  thinking...\033[0m", end="", flush=True)

        # Build command
        cmd = [self.claude_bin, "-p", "--output-format", "json"]
        if self.session_id:
            cmd.extend(["--resume", self.session_id])

        # Launch Claude (non-blocking)
        with self._lock:
            self._claude_proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            proc = self._claude_proc

        # Send prompt and wait for response in a way that can be interrupted
        try:
            stdout, stderr = proc.communicate(input=text, timeout=120)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            print("\r\033[2K\033[1;31m  timed out\033[0m")
            return

        with self._lock:
            self._claude_proc = None

        # Check if we were killed (interrupted)
        if proc.returncode != 0 and proc.returncode != 0:
            if proc.returncode == -9 or proc.returncode == -15:
                return  # Interrupted — don't print anything
            print(f"\r\033[2K\033[1;31m  error (code {proc.returncode})\033[0m")
            return

        # Parse JSON
        try:
            resp = json.loads(stdout)
        except json.JSONDecodeError:
            print("\r\033[2K\033[1;31m  bad response\033[0m")
            return

        response_text = resp.get("result", "")
        if not self.session_id:
            self.session_id = resp.get("session_id")

        if response_text:
            print(f"\r\033[2K\n{response_text}\n")
            sys.stdout.flush()
            self.tts_queue.put(response_text)


def main():
    cfg = load_config()

    claude_bin = shutil.which("claude")
    if not claude_bin:
        print("[voice_bridge] Error: claude not found on PATH", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(VOICE_FIFO):
        os.mkfifo(VOICE_FIFO)

    tts_queue: queue.Queue = queue.Queue()
    tts_worker = TTSWorker(tts_queue)
    bridge = VoiceBridge(claude_bin, tts_queue)

    print("\033[1mVoice Terminal\033[0m — Caps Lock to speak, Caps Lock again to interrupt")
    print(f"\033[2mlistening on {VOICE_FIFO}\033[0m\n")
    sys.stdout.flush()

    fifo_fd = open_fifo(VOICE_FIFO)
    if fifo_fd is None:
        sys.exit(1)

    # Run Claude calls in a worker thread so FIFO stays responsive
    request_queue: queue.Queue = queue.Queue()

    def _worker():
        while True:
            text = request_queue.get()
            if text is None:
                break
            bridge.send(text)

    worker_thread = threading.Thread(target=_worker, daemon=True)
    worker_thread.start()

    fifo_buf = b""
    try:
        while True:
            try:
                readable, _, _ = select.select([fifo_fd], [], [], 0.2)
            except (OSError, ValueError):
                try:
                    os.close(fifo_fd)
                except OSError:
                    pass
                fifo_fd = open_fifo(VOICE_FIFO)
                if fifo_fd is None:
                    break
                continue

            if fifo_fd not in readable:
                continue

            try:
                data = os.read(fifo_fd, 4096)
            except BlockingIOError:
                continue
            except OSError:
                os.close(fifo_fd)
                fifo_fd = open_fifo(VOICE_FIFO)
                if fifo_fd is None:
                    break
                continue

            if not data:
                os.close(fifo_fd)
                fifo_fd = open_fifo(VOICE_FIFO)
                if fifo_fd is None:
                    break
                continue

            fifo_buf += data
            while b"\n" in fifo_buf:
                line, fifo_buf = fifo_buf.split(b"\n", 1)
                text = line.decode("utf-8", errors="replace").strip()
                if not text:
                    continue

                if text == "__INTERRUPT__":
                    bridge.interrupt()
                    tts_worker.skip()
                    continue

                # Convert "slash <command>" to "/<command>"
                slash_match = re.match(r"^(?:slash|forward slash)\s+(.+)$", text, re.IGNORECASE)
                if slash_match:
                    text = "/" + slash_match.group(1).replace(" ", "-")

                # Interrupt any in-progress work, then queue new request
                bridge.interrupt()
                tts_worker.skip()
                request_queue.put(text)

    except KeyboardInterrupt:
        pass
    finally:
        request_queue.put(None)  # Signal worker to exit
        tts_worker.shutdown()
        if fifo_fd is not None:
            try:
                os.close(fifo_fd)
            except OSError:
                pass
        print("\n\033[2mSession ended.\033[0m")


if __name__ == "__main__":
    main()
