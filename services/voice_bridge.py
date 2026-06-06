#!/usr/bin/env python3
"""Voice bridge daemon for relay-mode voice sessions.

Supported app/script paths run with --relay: the bridge writes voice commands
to /tmp/voice_cmd_ready and reads spoken summaries from /tmp/tts_in.fifo. The
non-relay branch below is legacy Claude-only direct mode retained for manual
debugging; Start Session and the relay-bridge skills do not use it.
"""

from __future__ import annotations

import json
import os
import queue
import re
import select
import shutil
import signal
import socket
import stat
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


def ensure_fifo(path: str) -> bool:
    try:
        mode = os.stat(path).st_mode
    except FileNotFoundError:
        pass
    except OSError as e:
        print(f"[voice_bridge] Could not inspect FIFO {path}: {e}", file=sys.stderr)
        return False
    else:
        if stat.S_ISFIFO(mode):
            return True
        try:
            os.unlink(path)
        except OSError as e:
            print(f"[voice_bridge] Could not replace non-FIFO {path}: {e}", file=sys.stderr)
            return False

    try:
        os.mkfifo(path)
        return True
    except FileExistsError:
        try:
            return stat.S_ISFIFO(os.stat(path).st_mode)
        except OSError as e:
            print(f"[voice_bridge] Could not inspect FIFO {path}: {e}", file=sys.stderr)
            return False
    except OSError as e:
        print(f"[voice_bridge] Could not create FIFO {path}: {e}", file=sys.stderr)
        return False


def open_fifo(path: str) -> int | None:
    if not ensure_fifo(path):
        return None
    try:
        return os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError as e:
        print(f"[voice_bridge] Could not open FIFO {path}: {e}", file=sys.stderr)
        return None


class LegacyDirectVoiceBridge:
    """Legacy persistent `claude` session reused across voice prompts.

    This path is intentionally Claude-only and is not a supported user-facing
    launch mode anymore. The first prompt pays CLI startup + MCP-server-spawn
    cost (~5–7s on this machine); subsequent prompts reuse the warm process
    and only pay LLM inference time. Interrupt or crash respawns transparently,
    resuming the same Claude session via --resume so conversation context is
    preserved.
    """

    def __init__(self, claude_bin: str, tts_queue: queue.Queue, session_id: str | None = None):
        self.claude_bin = claude_bin
        self.tts_queue = tts_queue
        self.session_id: str | None = session_id
        self._proc: subprocess.Popen | None = None
        self._reader_thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._pending: dict | None = None

    def _spawn(self) -> subprocess.Popen | None:
        cmd = [
            self.claude_bin,
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions",
        ]
        if self.session_id:
            cmd.extend(["--resume", self.session_id])
        try:
            return subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except OSError as e:
            print(f"[voice_bridge] failed to spawn claude: {e}", file=sys.stderr)
            return None

    def _ensure_warm(self) -> bool:
        with self._lock:
            if self._proc and self._proc.poll() is None:
                return True
            if self._proc is not None:
                print(
                    f"[voice_bridge] warm session died (rc={self._proc.returncode}); respawning",
                    file=sys.stderr,
                )
                self._proc = None
            proc = self._spawn()
            if proc is None:
                return False
            self._proc = proc
            self._reader_thread = threading.Thread(
                target=self._read_stream, args=(proc,), daemon=True
            )
            self._reader_thread.start()
            return True

    def _read_stream(self, proc: subprocess.Popen):
        try:
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                sid = obj.get("session_id")
                if sid:
                    self.session_id = sid
                if obj.get("type") == "result":
                    pending = self._pending
                    if pending is not None and not pending["done"]:
                        pending["result_text"] = obj.get("result") or ""
                        pending["done"] = True
                        pending["event"].set()
        except (OSError, ValueError):
            pass
        finally:
            # Wake any pending request so send() doesn't hang on a dead process
            pending = self._pending
            if pending is not None and not pending["done"]:
                pending["done"] = True
                pending["interrupted"] = True
                pending["event"].set()

    def interrupt(self):
        """Kill the warm Claude process; next send() respawns and resumes."""
        with self._lock:
            proc = self._proc
            self._proc = None
        if proc and proc.poll() is None:
            proc.kill()
            proc.wait()
            print("\r\033[2K\033[1;33m  interrupted\033[0m")
            sys.stdout.flush()
        pending = self._pending
        if pending is not None and not pending["done"]:
            pending["interrupted"] = True
            pending["done"] = True
            pending["event"].set()

    def shutdown(self):
        """Close the warm session cleanly on bridge exit."""
        with self._lock:
            proc = self._proc
            self._proc = None
        if proc is None:
            return
        try:
            if proc.stdin and not proc.stdin.closed:
                proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    def send(self, text: str):
        """Send a message to Claude, display + speak the response."""
        print(f"\n\033[1;36m❯ {text}\033[0m")
        print("\033[2m  thinking...\033[0m", end="", flush=True)
        _notify_state("processing", prompt=text[:200])

        envelope = json.dumps({
            "type": "user",
            "message": {"role": "user", "content": text},
        }) + "\n"

        pending = {"event": threading.Event(), "result_text": None, "interrupted": False, "done": False}

        # Up to two attempts: first on warm session, second after respawn if write fails.
        for attempt in range(2):
            if not self._ensure_warm():
                print("\r\033[2K\033[1;31m  spawn failed\033[0m")
                _notify_state("idle")
                return
            self._pending = pending
            try:
                self._proc.stdin.write(envelope)
                self._proc.stdin.flush()
                break
            except (BrokenPipeError, OSError) as e:
                print(f"[voice_bridge] write to warm session failed ({e}); respawning",
                      file=sys.stderr)
                self._pending = None
                with self._lock:
                    self._proc = None
                if attempt == 1:
                    print("\r\033[2K\033[1;31m  send failed\033[0m")
                    _notify_state("idle")
                    return

        completed = pending["event"].wait(timeout=120)
        self._pending = None

        if not completed:
            print("\r\033[2K\033[1;31m  timed out\033[0m")
            self.interrupt()
            _notify_state("idle")
            return

        if pending["interrupted"]:
            _notify_state("idle")
            return

        _notify_state("idle")

        response_text = pending["result_text"] or ""
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


def _queue_tts_text(
    text: str,
    tts_queue: queue.Queue,
    command_path: str = VOICE_CMD_FILE,
) -> bool:
    """Queue TTS unless a newer Relay command is already waiting."""
    text = _strip_markdown_for_tts(text.strip()).strip()
    if not text:
        return False
    if os.path.exists(command_path):
        print(
            "[voice_bridge] Dropping TTS because a newer voice command is pending.",
            file=sys.stderr,
        )
        return False
    tts_queue.put(text)
    return True


def _tts_fifo_reader(tts_queue: queue.Queue, shutdown_event: threading.Event):
    """Read text from TTS input FIFO and put on TTS queue (relay mode only)."""
    while not shutdown_event.is_set():
        try:
            with open(TTS_IN_FIFO, "r") as f:
                for line in f:
                    if shutdown_event.is_set():
                        break
                    _queue_tts_text(line, tts_queue)
        except OSError:
            if not shutdown_event.is_set():
                import time
                time.sleep(0.2)


def _run_relay(tts_worker: TTSWorker, shutdown_event: threading.Event):
    """Relay mode: write voice commands for the active agent and read TTS from FIFO."""
    # Create TTS input FIFO
    for path in [TTS_IN_FIFO, VOICE_CMD_FILE]:
        try:
            os.unlink(path)
        except OSError:
            pass

    if not ensure_fifo(TTS_IN_FIFO):
        return

    # Start TTS input reader thread
    tts_reader = threading.Thread(
        target=_tts_fifo_reader,
        args=(tts_worker.input_queue, shutdown_event),
        daemon=True,
    )
    tts_reader.start()

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

                # Skip TTS for new voice input, write command for the agent
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


def _write_cmd_file(text: str, path: str = VOICE_CMD_FILE):
    """Atomically write a voice command to the ready file."""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.rename(tmp, path)


def main():
    cfg = load_config()
    cli = _parse_args()
    relay_mode = cli.get("relay", False)

    if not relay_mode:
        # Legacy direct mode is intentionally Claude-only. The supported
        # script/app entry points always pass --relay and run Codex or Claude
        # through the installed relay-bridge skill/command instead.
        claude_bin = shutil.which("claude")
        if not claude_bin:
            print("[voice_bridge] Error: claude not found on PATH", file=sys.stderr)
            sys.exit(1)

    if not ensure_fifo(VOICE_FIFO):
        sys.exit(1)

    tts_queue: queue.Queue = queue.Queue()
    tts_worker = TTSWorker(tts_queue)

    shutdown_event = threading.Event()

    # Control socket for reload/shutdown from Tauri app
    control_thread = threading.Thread(
        target=_start_control_socket, args=(tts_worker, shutdown_event), daemon=True
    )
    control_thread.start()

    # Relay mode: daemon for the relay-bridge skill/command
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

    bridge = LegacyDirectVoiceBridge(claude_bin, tts_queue, session_id=cli.get("session"))

    print("\033[1mRelay Runner\033[0m — Caps Lock to speak, Caps Lock again to interrupt")
    if bridge.session_id:
        print(f"\033[2mResuming session: {bridge.session_id}\033[0m")
    print(f"\033[2mlistening on {VOICE_FIFO}\033[0m\n")
    sys.stdout.flush()

    fifo_fd = open_fifo(VOICE_FIFO)
    if fifo_fd is None:
        sys.exit(1)

    # Run legacy Claude calls in a worker thread so FIFO stays responsive
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

                # Interrupt any in-progress legacy Claude request, stop TTS audio
                # (but don't discard pending text — user may still want to play it)
                bridge.interrupt()
                tts_worker.stop_playback()
                request_queue.put(text)

    except KeyboardInterrupt:
        pass
    finally:
        shutdown_event.set()
        request_queue.put(None)  # Signal worker to exit
        bridge.shutdown()
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
