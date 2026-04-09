#!/usr/bin/env python3
"""PTY wrapper that multiplexes keyboard + voice FIFO into a child process."""

import errno
import fcntl
import os
import pty
import signal
import struct
import sys
import termios
import tty

from tts_filter import TTSFilter
from tts_worker import TTSWorker

VOICE_FIFO = os.environ.get("VOICE_FIFO", "/tmp/voice_in.fifo")
CHUNK_TIMEOUT = float(os.environ.get("CHUNK_TIMEOUT", "0.4"))


def set_nonblock(fd):
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)


def get_winsize(fd):
    try:
        return fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\x00" * 8)
    except OSError:
        return struct.pack("HHHH", 24, 80, 0, 0)


def set_winsize(fd, winsize):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)


def open_fifo(path):
    """Open the voice FIFO for reading (non-blocking). Returns fd or None."""
    if not os.path.exists(path):
        try:
            os.mkfifo(path)
        except OSError as e:
            print(f"[voice_wrap] Could not create FIFO {path}: {e}", file=sys.stderr)
            return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        return fd
    except OSError as e:
        print(f"[voice_wrap] Could not open FIFO {path}: {e}", file=sys.stderr)
        return None


def main():
    cmd = sys.argv[1:] if len(sys.argv) > 1 else ["claude"]

    # Save original terminal settings
    stdin_fd = sys.stdin.fileno()
    old_termios = termios.tcgetattr(stdin_fd)

    # Open voice FIFO
    fifo_fd = open_fifo(VOICE_FIFO)

    # Create TTS filter → TTS worker pipeline
    tts_filter = TTSFilter(chunk_timeout=CHUNK_TIMEOUT)
    tts_worker = TTSWorker(tts_filter.output_queue)

    # Fork a child in a PTY
    child_pid, master_fd = pty.fork()

    if child_pid == 0:
        # Child process — exec the target command
        os.execvp(cmd[0], cmd)
        # If exec fails
        sys.exit(1)

    # Parent process
    # Set initial window size on child PTY
    winsize = get_winsize(stdin_fd)
    set_winsize(master_fd, winsize)

    # Handle SIGWINCH — resize child PTY
    def handle_winch(signum, frame):
        ws = get_winsize(stdin_fd)
        set_winsize(master_fd, ws)
        # Forward to child
        os.kill(child_pid, signal.SIGWINCH)

    signal.signal(signal.SIGWINCH, handle_winch)

    # Put real stdin into raw mode so keystrokes pass through
    tty.setraw(stdin_fd)
    set_nonblock(master_fd)

    fifo_buf = b""

    try:
        import select as sel

        while True:
            rfds = [stdin_fd, master_fd]
            if fifo_fd is not None:
                rfds.append(fifo_fd)

            try:
                readable, _, _ = sel.select(rfds, [], [], 0.1)
            except (OSError, ValueError):
                break

            # Keyboard input → child
            if stdin_fd in readable:
                try:
                    data = os.read(stdin_fd, 4096)
                    if not data:
                        break
                    os.write(master_fd, data)
                except OSError:
                    break

            # Child output → real stdout + TTS filter
            if master_fd in readable:
                try:
                    data = os.read(master_fd, 4096)
                    if not data:
                        break
                    os.write(sys.stdout.fileno(), data)
                    tts_filter.feed(data)
                except OSError as e:
                    if e.errno == errno.EIO:
                        # Child exited
                        break
                    raise

            # Voice FIFO → child stdin
            if fifo_fd is not None and fifo_fd in readable:
                try:
                    data = os.read(fifo_fd, 4096)
                    if data:
                        fifo_buf += data
                        # Process complete lines
                        while b"\n" in fifo_buf:
                            line, fifo_buf = fifo_buf.split(b"\n", 1)
                            text = line.strip()
                            if text:
                                # Write to child as if typed, then press Enter
                                os.write(master_fd, text + b"\n")
                    else:
                        # Writer closed FIFO — reopen to wait for next writer
                        os.close(fifo_fd)
                        fifo_fd = open_fifo(VOICE_FIFO)
                except OSError:
                    os.close(fifo_fd)
                    fifo_fd = open_fifo(VOICE_FIFO)

            # Check if child is still alive
            pid, status = os.waitpid(child_pid, os.WNOHANG)
            if pid != 0:
                break

    except KeyboardInterrupt:
        pass
    finally:
        # Restore terminal
        termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_termios)
        tts_filter.shutdown()
        tts_worker.shutdown()
        if fifo_fd is not None:
            try:
                os.close(fifo_fd)
            except OSError:
                pass
        # Clean up child
        try:
            os.kill(child_pid, signal.SIGTERM)
            os.waitpid(child_pid, 0)
        except (OSError, ChildProcessError):
            pass

    print("\n[voice_wrap] Session ended.")


if __name__ == "__main__":
    main()
