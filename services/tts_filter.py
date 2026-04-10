#!/usr/bin/env python3
"""Filters terminal output, stripping code/tool/ANSI content. Keeps natural language."""

import queue
import re
import threading
import time


# ANSI cursor-movement sequences — replace with space to preserve word boundaries
_ANSI_CURSOR_RE = re.compile(
    r"\x1b\[[0-9;]*[ABCDGHJ]"      # Cursor movement (up/down/fwd/back/pos)
    r"|\x1b\[[0-9;]*[fH]"          # Cursor position
    r"|\r"                          # Carriage return
)

# ANSI escape sequences — strip completely
_ANSI_RE = re.compile(
    r"\x1b\[[0-9;]*[A-Za-z]"       # CSI sequences
    r"|\x1b\].*?\x07"              # OSC sequences
    r"|\x1b\(B"                    # Character set
    r"|\x1b\[[\?0-9;]*[hlm]"      # Mode set/reset
    r"|\x1b\[[<>=?]?[0-9;]*[a-zA-Z]"  # Extended CSI (kitty etc.)
    r"|\[<u\[>[0-9;]*[a-zA-Z]*"   # Kitty progressive enhancement
    r"|\[>[0-9;]*[a-zA-Z]"        # DA2 responses
)

# Claude Code spinner/status characters
_CLAUDE_SPINNER_CHARS = set("✽✻✶✳✢·⏺●◐◑◒◓")

# Spinner / progress characters
_SPINNER_RE = re.compile(r"^[\s]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⣾⣽⣻⢿⡿⣟⣯⣷|/\\-]+[\s]*$")

# Claude Code status words — strip regardless of prefix. Claude cycles through
# many creative words as spinner text; match broadly with a trailing ellipsis.
_CLAUDE_STATUS_RE_LINE = re.compile(r"^.*\w+…\s*$")
_CLAUDE_STATUS_WORDS = [
    "Composing", "Actualizing", "Thinking", "Generating", "Streaming",
    "Processing", "Compiling", "Building", "Running", "Installing",
    "Reading", "Editing", "Writing", "Searching", "Fetching",
    "Honking", "Pondering", "Reasoning", "Analyzing", "Computing",
    "Crafting", "Preparing", "Loading", "Parsing", "Resolving",
    "Imagining", "Considering", "Deliberating", "Evaluating",
    "Formulating", "Synthesizing", "Deciphering", "Interpreting",
]

# Shell prompt patterns
_PROMPT_RE = re.compile(r"^[\s]*([\$#>%]|\w+@\w+[:\$#]|❯|➜|\(.*\)[\s]*[\$#>])")

# Tool use markers from Claude Code
_TOOL_MARKERS = [
    "⏺", "●", "◐", "◑", "◒", "◓",  # Activity indicators
    "Read(", "Edit(", "Write(", "Bash(", "Glob(", "Grep(",  # Tool calls
    "Agent(", "Search(", "WebFetch(", "WebSearch(",  # More tool calls
    "⎿",  # Tool result prefix
    "Thinking", "thinking",  # Thinking indicators
]

# Claude Code status/UI lines to skip entirely
_STATUS_RE = re.compile(
    r"^[\s]*(Thinking|thinking|Generating|Streaming|Processing|Compiling|Building|Running|Installing"
    r"|Reading|Editing|Writing|Searching|Fetching"
    r"|[\d]+%|[\d]+/[\d]+"  # Progress indicators
    r"|\.{2,}"  # Ellipsis lines
    r"|[-=]{3,}"  # Horizontal rules
    r"|[*_]{1,3}\S)"  # Markdown emphasis at start of line
)

# Inline code pattern (backtick-wrapped)
_INLINE_CODE_RE = re.compile(r"`[^`]+`")

# Markdown emphasis (bold, italic) — strip markers, keep text
_MD_EMPHASIS_RE = re.compile(r"\*{1,3}([^*]+)\*{1,3}")
_MD_UNDERSCORE_RE = re.compile(r"_{1,3}([^_]+)_{1,3}")

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

    _log = open("/tmp/tts_debug.log", "a")

    def _log_line(self, tag: str, text: str):
        self._log.write(f"[tts_filter] {tag}: {text[:120]}\n")
        self._log.flush()

    def _process_line(self, raw_line: str):
        """Run a single line through the state machine."""
        # Replace cursor-movement sequences with spaces (preserves word boundaries)
        spaced = _ANSI_CURSOR_RE.sub(" ", raw_line)
        # Then strip remaining ANSI escapes
        clean = _ANSI_RE.sub("", spaced)
        # Collapse multiple spaces
        clean = re.sub(r"  +", " ", clean).rstrip()

        # Fence code block transitions
        if clean.lstrip().startswith("```"):
            if self._state == self.FENCE:
                self._state = self.NORMAL
            else:
                self._state = self.FENCE
            self._log_line("SKIP fence", clean)
            return

        if self._state == self.FENCE:
            self._log_line("SKIP in-fence", clean)
            return  # Skip everything inside fenced blocks

        # Tool use detection
        if any(clean.lstrip().startswith(m) for m in _TOOL_MARKERS):
            self._state = self.TOOL
            self._log_line("SKIP tool-start", clean)
            return

        # Blank line resets tool state
        if not clean.strip():
            if self._state == self.TOOL:
                self._state = self.NORMAL
            self._flush_pending()
            return

        if self._state == self.TOOL:
            self._log_line("SKIP tool-body", clean)
            return  # Skip tool output lines

        # Filter out non-natural-language lines
        if self._should_strip(clean):
            self._log_line("SKIP strip", clean)
            return

        # This line is natural language — clean it up for TTS
        spoken = _INLINE_CODE_RE.sub("", clean)
        spoken = _MD_EMPHASIS_RE.sub(r"\1", spoken)
        spoken = _MD_UNDERSCORE_RE.sub(r"\1", spoken)
        # Remove spinner characters
        spoken = "".join(c for c in spoken if c not in _CLAUDE_SPINNER_CHARS)
        # Remove any trailing "Word…" status pattern (catches all spinner words)
        spoken = re.sub(r"\s*\w+…\s*$", "", spoken)
        spoken = spoken.strip()
        if len(spoken) > 4:
            self._log_line("SPEAK", spoken)
            self._pending_lines.append(spoken)

    def _should_strip(self, line: str) -> bool:
        """Return True if this line should be stripped (not natural language)."""
        stripped = line.strip()
        # Strip spinner-char prefix for analysis
        core = stripped.lstrip("".join(_CLAUDE_SPINNER_CHARS)).strip()
        # Very short fragments — streaming artifacts (individual chars/pairs)
        if len(stripped) <= 4:
            return True
        # Claude Code status words (with any spinner prefix)
        for word in _CLAUDE_STATUS_WORDS:
            if core.startswith(word):
                return True
        # Horizontal rules and box-drawing characters
        if all(c in "─═━—–-=_│|┌┐└┘├┤┬┴┼ " for c in stripped):
            return True
        # Claude Code status bar patterns
        if "context)" in stripped or "│" in stripped:
            return True
        # Model identifiers
        if core.startswith("Opus") or core.startswith("Sonnet") or core.startswith("Haiku"):
            return True
        # MCP / remote-control status
        if "MCP" in stripped or "remote-control" in stripped or "session_" in stripped:
            return True
        # Claude Code status/UI lines
        if _STATUS_RE.match(stripped):
            return True
        # Spinner/progress
        if _SPINNER_RE.match(stripped):
            return True
        # Shell prompt
        if _PROMPT_RE.match(stripped):
            return True
        # Code-like lines
        if _CODE_LINE_RE.match(stripped):
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
