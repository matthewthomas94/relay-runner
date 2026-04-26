#!/usr/bin/env python3
"""Voice bridge — connects voice FIFO to Claude Code via JSON API, feeds TTS."""

from __future__ import annotations

import json
import os
import queue
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import threading

from config import load_config
from tts_worker import TTSWorker

VOICE_FIFO = os.environ.get("VOICE_FIFO", "/tmp/voice_in.fifo")
BRIDGE_CONTROL_SOCK = os.environ.get("BRIDGE_CONTROL_SOCK", "/tmp/voice_bridge.sock")
VOICE_STATE_SOCK = "/tmp/voice_state.sock"


def _notify_state(state: str, **kwargs):
    """Send a state update to the overlay app via Unix datagram socket."""
    msg = {"source": "bridge", "state": state, **kwargs}
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.sendto(json.dumps(msg).encode(), VOICE_STATE_SOCK)
        s.close()
    except (OSError, ConnectionRefusedError):
        pass


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
    def __init__(self, claude_bin: str, tts_queue: queue.Queue, session_id: str | None = None):
        self.claude_bin = claude_bin
        self.tts_queue = tts_queue
        self.session_id: str | None = session_id
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
        _notify_state("processing", prompt=text[:200])

        # Build command
        cmd = [self.claude_bin, "-p", "--output-format", "json", "--dangerously-skip-permissions"]
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

        _notify_state("idle")

        if response_text:
            print(f"\r\033[2K\n{response_text}\n")
            sys.stdout.flush()
            self.tts_queue.put(response_text)


VOICE_CMD_FILE = "/tmp/voice_cmd_ready"
TTS_IN_FIFO = "/tmp/tts_in.fifo"


def _parse_args() -> dict:
    """Parse CLI args: --config <path>, --session <id>, --relay."""
    args = sys.argv[1:]
    result: dict = {}
    for i, arg in enumerate(args):
        if arg == "--session" and i + 1 < len(args):
            result["session"] = args[i + 1]
        elif arg == "--relay":
            result["relay"] = True
    return result


def _start_control_socket(tts_worker: TTSWorker, shutdown_event: threading.Event):
    """Listen on Unix socket for reload/shutdown commands from Tauri or relay-bridge."""
    try:
        os.unlink(BRIDGE_CONTROL_SOCK)
    except OSError:
        pass

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(BRIDGE_CONTROL_SOCK)
    sock.settimeout(0.5)

    try:
        while not shutdown_event.is_set():
            try:
                data, _ = sock.recvfrom(256)
                cmd = data.decode("utf-8", errors="replace").strip()
                cmd_lower = cmd.lower()
                if cmd_lower == "reload":
                    print("[voice_bridge] Reloading config...", file=sys.stderr)
                    tts_worker.reload_config()
                elif cmd_lower == "shutdown":
                    print("[voice_bridge] Shutdown requested.", file=sys.stderr)
                    shutdown_event.set()
                elif cmd_lower == "ping":
                    pass  # Liveness probe — socket exists = alive
            except socket.timeout:
                continue
    finally:
        sock.close()
        try:
            os.unlink(BRIDGE_CONTROL_SOCK)
        except OSError:
            pass


# Strip markdown formatting before TTS so Kokoro doesn't pronounce literal
# *, _, ` as "asterisk", "underscore", "backtick". The skill prompt asks
# Claude to send plain prose, but it routinely returns **bold**, `code`, and
# blockquotes anyway — handle it server-side so the voice always sounds clean.
_MD_LINK_RE = re.compile(r"\[([^\]]+)\]\([^)]+\)")
_MD_LINE_PREFIX_RE = re.compile(r"^\s*(?:>+|#+|[-+*]|\d+\.)\s+")


def _strip_markdown_for_tts(text: str) -> str:
    """Strip markdown so Kokoro doesn't pronounce */_/` aloud."""
    text = _MD_LINK_RE.sub(r"\1", text)        # [label](url) → label
    text = _MD_LINE_PREFIX_RE.sub("", text)    # leading >, #, -, *, 1. → drop
    return re.sub(r"[*_`]", "", text)          # any remaining markers


def _tts_fifo_reader(tts_queue: queue.Queue, shutdown_event: threading.Event):
    """Read text from TTS input FIFO and put on TTS queue (relay mode only)."""
    while not shutdown_event.is_set():
        try:
            with open(TTS_IN_FIFO, "r") as f:
                for line in f:
                    if shutdown_event.is_set():
                        break
                    text = _strip_markdown_for_tts(line.strip()).strip()
                    if text:
                        tts_queue.put(text)
        except OSError:
            if not shutdown_event.is_set():
                import time
                time.sleep(0.2)


def _run_relay(tts_worker: TTSWorker, shutdown_event: threading.Event):
    """Relay mode: read voice FIFO, write commands to file for Claude, read TTS from FIFO."""
    # Create TTS input FIFO
    for path in [TTS_IN_FIFO, VOICE_CMD_FILE]:
        try:
            os.unlink(path)
        except OSError:
            pass

    try:
        os.mkfifo(TTS_IN_FIFO)
    except OSError:
        pass

    # Start TTS input reader thread
    tts_reader = threading.Thread(
        target=_tts_fifo_reader,
        args=(tts_worker.input_queue, shutdown_event),
        daemon=True,
    )
    tts_reader.start()

    if not os.path.exists(VOICE_FIFO):
        os.mkfifo(VOICE_FIFO)

    print("[voice_bridge] Relay mode — waiting for voice input...", file=sys.stderr)
    print(f"[voice_bridge] Voice commands → {VOICE_CMD_FILE}", file=sys.stderr)
    print(f"[voice_bridge] TTS input ← {TTS_IN_FIFO}", file=sys.stderr)

    fifo_fd = open_fifo(VOICE_FIFO)
    if fifo_fd is None:
        return

    fifo_buf = b""
    try:
        while not shutdown_event.is_set():
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

                # Handle control messages internally
                if text == "__TTS_STOP__":
                    # Kill TTS playback only — don't clear pending text or
                    # write to command file (preserves double-tap play and
                    # allows queued TTS to be synthesized)
                    tts_worker.stop_playback()
                    continue

                if text == "__INTERRUPT__":
                    tts_worker.stop_playback()
                    _write_cmd_file("__INTERRUPT__")
                    continue

                if text == "__CANCEL__":
                    tts_worker.skip()
                    _write_cmd_file("__INTERRUPT__")
                    continue

                if text == "__PLAY__":
                    tts_worker.play()
                    continue

                if text == "__REPLAY__":
                    tts_worker.replay()
                    continue

                if text.startswith("__STATUS__:"):
                    continue

                # Convert "slash <command>" to "/<command>"
                slash_match = re.match(r"^(?:slash|forward slash)\s+(.+)$", text, re.IGNORECASE)
                if slash_match:
                    text = "/" + slash_match.group(1).replace(" ", "-")

                # Skip TTS for new voice input, write command for Claude
                tts_worker.skip()
                _notify_state("processing", prompt=text[:200])
                _write_cmd_file(text)
                print(f"[voice_bridge] Voice command ready: {text}", file=sys.stderr)

    except KeyboardInterrupt:
        pass
    finally:
        if fifo_fd is not None:
            try:
                os.close(fifo_fd)
            except OSError:
                pass
        for path in [TTS_IN_FIFO, VOICE_CMD_FILE]:
            try:
                os.unlink(path)
            except OSError:
                pass


def _write_cmd_file(text: str):
    """Atomically write a voice command to the ready file."""
    tmp = VOICE_CMD_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.rename(tmp, VOICE_CMD_FILE)


def main():
    cfg = load_config()
    cli = _parse_args()
    relay_mode = cli.get("relay", False)

    if not relay_mode:
        claude_bin = shutil.which("claude")
        if not claude_bin:
            print("[voice_bridge] Error: claude not found on PATH", file=sys.stderr)
            sys.exit(1)

    if not os.path.exists(VOICE_FIFO):
        os.mkfifo(VOICE_FIFO)

    tts_queue: queue.Queue = queue.Queue()
    tts_worker = TTSWorker(tts_queue)

    shutdown_event = threading.Event()

    # Control socket for reload/shutdown from Tauri app
    control_thread = threading.Thread(
        target=_start_control_socket, args=(tts_worker, shutdown_event), daemon=True
    )
    control_thread.start()

    # Relay mode: daemon for Claude Code slash command
    if relay_mode:
        try:
            _run_relay(tts_worker, shutdown_event)
        finally:
            shutdown_event.set()
            tts_worker.shutdown()
            try:
                os.unlink(BRIDGE_CONTROL_SOCK)
            except OSError:
                pass
        return

    bridge = VoiceBridge(claude_bin, tts_queue, session_id=cli.get("session"))

    print("\033[1mRelay Runner\033[0m — Caps Lock to speak, Caps Lock again to interrupt")
    if bridge.session_id:
        print(f"\033[2mResuming session: {bridge.session_id}\033[0m")
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
        while not shutdown_event.is_set():
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

                if text == "__TTS_STOP__":
                    tts_worker.stop_playback()
                    continue

                if text == "__INTERRUPT__":
                    bridge.interrupt()
                    tts_worker.stop_playback()
                    continue

                if text == "__CANCEL__":
                    bridge.interrupt()
                    tts_worker.skip()  # Clear pending text so next message gets fresh notification
                    continue

                if text == "__PLAY__":
                    tts_worker.play()
                    continue

                if text == "__REPLAY__":
                    tts_worker.replay()
                    continue

                if text.startswith("__STATUS__:"):
                    status_msg = text[len("__STATUS__:"):]
                    print(f"\033[2m  [{status_msg}]\033[0m")
                    sys.stdout.flush()
                    continue

                # Convert "slash <command>" to "/<command>"
                slash_match = re.match(r"^(?:slash|forward slash)\s+(.+)$", text, re.IGNORECASE)
                if slash_match:
                    text = "/" + slash_match.group(1).replace(" ", "-")

                # Interrupt any in-progress Claude request, stop TTS audio
                # (but don't discard pending text — user may still want to play it)
                bridge.interrupt()
                tts_worker.stop_playback()
                request_queue.put(text)

    except KeyboardInterrupt:
        pass
    finally:
        shutdown_event.set()
        request_queue.put(None)  # Signal worker to exit
        tts_worker.shutdown()
        if fifo_fd is not None:
            try:
                os.close(fifo_fd)
            except OSError:
                pass
        try:
            os.unlink(BRIDGE_CONTROL_SOCK)
        except OSError:
            pass
        print("\n\033[2mSession ended.\033[0m")


if __name__ == "__main__":
    main()
