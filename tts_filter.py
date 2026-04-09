#!/usr/bin/env python3
"""Filters terminal output, stripping code/tool/ANSI content. Keeps natural language."""

import queue
import re
import threading
import time


# ANSI escape sequence pattern
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x1b\].*?\x07|\x1b\(B|\x1b\[[\?0-9;]*[hlm]")

# Spinner / progress characters
_SPINNER_RE = re.compile(r"^[\s]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⣾⣽⣻⢿⡿⣟⣯⣷|/\\-]+[\s]*$")

# Shell prompt patterns
_PROMPT_RE = re.compile(r"^[\s]*([\$#>%]|\w+@\w+[:\$#]|❯|➜|\(.*\)[\s]*[\$#>])")

# Tool use markers from Claude Code
_TOOL_MARKERS = [
    "⏺", "●", "◐", "◑", "◒", "◓",  # Activity indicators
    "Read(", "Edit(", "Write(", "Bash(", "Glob(", "Grep(",  # Tool calls
    "⎿",  # Tool result prefix
]

# Inline code pattern (backtick-wrapped)
_INLINE_CODE_RE = re.compile(r"`[^`]+`")

# Lines that look like file paths or code
_CODE_LINE_RE = re.compile(
    r"^[\s]*(import |from |def |class |function |const |let |var |"
    r"return |if \(|for \(|while \(|switch \(|try\s*\{|catch\s*\(|"
    r"[\{\}\[\];]|//|/\*|\*/|#!|<!|-->|"
    r"[a-zA-Z_]\w*\(.*\)\s*[{;:]?\s*$|"  # function calls
    r"\S+\.\S+\()"  # method calls
)


class TTSFilter:
    """
    State machine that parses raw terminal bytes and emits natural language chunks.

    States:
        NORMAL   — scanning for text vs code
        FENCE    — inside a fenced code block (``` ... ```)
        TOOL     — inside tool use output block
    """

    NORMAL = "normal"
    FENCE = "fence"
    TOOL = "tool"

    def __init__(self, chunk_timeout=0.4, output_queue=None):
        self._state = self.NORMAL
        self._buffer = ""
        self._chunk_timeout = chunk_timeout
        self._last_feed = 0.0
        self._pending_lines = []
        self._lock = threading.Lock()
        self._shutdown = False

        # Output queue — tts_worker reads from this
        if output_queue is not None:
            self.output_queue = output_queue
        else:
            self.output_queue = queue.Queue()

        # Flush timer thread
        self._timer = threading.Thread(target=self._flush_loop, daemon=True)
        self._timer.start()

    def feed(self, data: bytes):
        """Feed raw terminal output bytes."""
        try:
            text = data.decode("utf-8", errors="replace")
        except Exception:
            return

        with self._lock:
            self._buffer += text
            self._last_feed = time.monotonic()
            self._process_buffer()

    def _process_buffer(self):
        """Process complete lines from the buffer."""
        while "\n" in self._buffer:
            line, self._buffer = self._buffer.split("\n", 1)
            self._process_line(line)

    def _process_line(self, raw_line: str):
        """Run a single line through the state machine."""
        # Strip ANSI escapes for analysis
        clean = _ANSI_RE.sub("", raw_line).rstrip()

        # Fence code block transitions
        if clean.lstrip().startswith("```"):
            if self._state == self.FENCE:
                self._state = self.NORMAL
            else:
                self._state = self.FENCE
            return

        if self._state == self.FENCE:
            return  # Skip everything inside fenced blocks

        # Tool use detection
        if any(clean.lstrip().startswith(m) for m in _TOOL_MARKERS):
            self._state = self.TOOL
            return

        # Blank line resets tool state
        if not clean.strip():
            if self._state == self.TOOL:
                self._state = self.NORMAL
            # Blank lines can also delimit paragraphs — flush pending
            self._flush_pending()
            return

        if self._state == self.TOOL:
            return  # Skip tool output lines

        # Filter out non-natural-language lines
        if self._should_strip(clean):
            return

        # This line is natural language — collect it
        # Remove inline code for TTS readability
        spoken = _INLINE_CODE_RE.sub("", clean).strip()
        if spoken:
            self._pending_lines.append(spoken)

    def _should_strip(self, line: str) -> bool:
        """Return True if this line should be stripped (not natural language)."""
        # Spinner/progress
        if _SPINNER_RE.match(line):
            return True
        # Shell prompt
        if _PROMPT_RE.match(line):
            return True
        # Code-like lines
        if _CODE_LINE_RE.match(line):
            return True
        # Very short lines that look like symbols/artifacts
        stripped = line.strip()
        if len(stripped) <= 2 and not stripped[-1:].isalpha():
            return True
        return False

    def _flush_pending(self):
        """Send collected lines to the output queue as a single chunk."""
        if not self._pending_lines:
            return
        chunk = " ".join(self._pending_lines)
        self._pending_lines = []
        if chunk.strip():
            self.output_queue.put(chunk)

    def _flush_loop(self):
        """Background thread: flush pending lines after chunk_timeout of silence."""
        while not self._shutdown:
            time.sleep(0.1)
            with self._lock:
                if (
                    self._pending_lines
                    and self._last_feed
                    and (time.monotonic() - self._last_feed) >= self._chunk_timeout
                ):
                    self._flush_pending()

    def shutdown(self):
        """Flush remaining content and stop the timer thread."""
        self._shutdown = True
        with self._lock:
            # Process any remaining buffer content
            if self._buffer.strip():
                self._process_line(self._buffer)
                self._buffer = ""
            self._flush_pending()
