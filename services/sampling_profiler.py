"""Opt-in, in-process sampling profiler for the orchestrator daemon.

Off unless ``RELAY_ORCHESTRATOR_PROFILE`` names an output file. Off means no
thread, no file and no per-request cost: the daemon only checks the variable
once at startup.

When on, one daemon thread wakes every ``RELAY_ORCHESTRATOR_PROFILE_INTERVAL_MS``
(default 10 ms), reads ``sys._current_frames()`` and charges each thread's
Python stack with the CPU that thread used since the previous sample. On macOS
that per-thread CPU comes from ``proc_pidinfo``, so threads that are waiting
cost nothing and drop out of the profile; elsewhere each stack is charged the
wall-clock interval instead. The output holds collapsed stacks, one
``thread;file.py:function;... <microseconds>`` line per stack, which
flamegraph.pl and speedscope read directly. It is rewritten atomically every
few seconds and when the daemon stops. The profiler's own CPU appears as the
``(profiler)`` line, so its overhead is visible.
"""

from __future__ import annotations

import ctypes
import os
import re
import sys
import threading
import time
from pathlib import Path
from typing import Callable, Mapping

PROFILE_ENV = "RELAY_ORCHESTRATOR_PROFILE"
INTERVAL_ENV = "RELAY_ORCHESTRATOR_PROFILE_INTERVAL_MS"
DEFAULT_INTERVAL_MS = 10.0
FLUSH_SECONDS = 5.0

_PROC_PIDTHREADID64INFO = 15


class _ProcThreadInfo(ctypes.Structure):
    _fields_ = [
        ("pth_user_time", ctypes.c_uint64),
        ("pth_system_time", ctypes.c_uint64),
        ("pth_cpu_usage", ctypes.c_int32),
        ("pth_policy", ctypes.c_int32),
        ("pth_run_state", ctypes.c_int32),
        ("pth_flags", ctypes.c_int32),
        ("pth_sleep_time", ctypes.c_int32),
        ("pth_curpri", ctypes.c_int32),
        ("pth_priority", ctypes.c_int32),
        ("pth_maxpriority", ctypes.c_int32),
        ("pth_name", ctypes.c_char * 64),
    ]


def darwin_thread_cpu_reader() -> Callable[[int], float | None] | None:
    """Return native thread id -> CPU seconds, or None off macOS."""
    if sys.platform != "darwin":
        return None
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    except OSError:
        return None
    proc_pidinfo = libproc.proc_pidinfo
    proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    proc_pidinfo.restype = ctypes.c_int
    pid = os.getpid()
    info = _ProcThreadInfo()
    size = ctypes.sizeof(info)

    def read(native_id: int) -> float | None:
        if proc_pidinfo(pid, _PROC_PIDTHREADID64INFO, native_id, ctypes.byref(info), size) != size:
            return None
        return (info.pth_user_time + info.pth_system_time) / 1e9

    return read


def _frame_label(code) -> str:
    return f"{os.path.basename(code.co_filename)}:{getattr(code, 'co_qualname', code.co_name)}"


def _thread_label(name: str) -> str:
    # Request and worker threads carry counters; fold them into one family.
    return re.sub(r"\d+", "N", name).replace(";", ",").replace(" ", "_")


class SamplingProfiler:
    def __init__(
        self,
        output: Path,
        interval: float = DEFAULT_INTERVAL_MS / 1000,
        *,
        flush_interval: float = FLUSH_SECONDS,
        cpu_reader: Callable[[int], float | None] | None = None,
    ):
        self.output = Path(output)
        self.interval = interval
        self.flush_interval = flush_interval
        self._cpu_reader = cpu_reader
        self._stacks: dict[str, int] = {}
        self._last_cpu: dict[int, float] = {}
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    @property
    def measures_cpu(self) -> bool:
        return self._cpu_reader is not None

    def start(self) -> None:
        if self._cpu_reader is None:
            self._cpu_reader = darwin_thread_cpu_reader()
        self._thread = threading.Thread(target=self._run, name="sampling-profiler", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
        self.flush()

    def snapshot(self) -> dict[str, int]:
        with self._lock:
            return dict(self._stacks)

    def flush(self) -> None:
        lines = [f"{stack} {weight}\n" for stack, weight in sorted(self.snapshot().items()) if weight > 0]
        temporary = self.output.with_name(self.output.name + ".tmp")
        temporary.write_text("".join(lines))
        os.replace(temporary, self.output)

    def _run(self) -> None:
        own = threading.get_ident()
        last_wall = time.monotonic()
        next_flush = last_wall + self.flush_interval
        while not self._stop.wait(self.interval):
            now = time.monotonic()
            self._sample(own, now - last_wall)
            last_wall = now
            if now >= next_flush:
                next_flush = now + self.flush_interval
                try:
                    self.flush()
                except OSError as error:
                    print(f"[sampling-profiler] could not write {self.output}: {error}", file=sys.stderr)

    def _charge(self, stack: str, seconds: float) -> None:
        micros = int(seconds * 1_000_000)
        if micros > 0:
            with self._lock:
                self._stacks[stack] = self._stacks.get(stack, 0) + micros

    def _sample(self, own: int, wall: float) -> None:
        frames = sys._current_frames()
        threads = {thread.ident: thread for thread in threading.enumerate()}
        live: set[int] = set()
        for ident, frame in frames.items():
            thread = threads.get(ident)
            native_id = getattr(thread, "native_id", None)
            weight = wall
            if self._cpu_reader is not None:
                if native_id is None:
                    continue
                cpu = self._cpu_reader(native_id)
                if cpu is None:
                    continue
                live.add(native_id)
                previous = self._last_cpu.get(native_id)
                self._last_cpu[native_id] = cpu
                if previous is None:
                    continue
                weight = cpu - previous
            if weight <= 0:
                continue
            if ident == own:
                self._charge("(profiler)", weight)
                continue
            parts = []
            while frame is not None:
                parts.append(_frame_label(frame.f_code))
                frame = frame.f_back
            name = _thread_label(thread.name if thread is not None else f"thread-{ident}")
            self._charge(";".join([name, *reversed(parts)]), weight)
        if self._cpu_reader is not None:
            for native_id in list(self._last_cpu):
                if native_id not in live:
                    del self._last_cpu[native_id]


def start_from_environment(environ: Mapping[str, str] = os.environ) -> SamplingProfiler | None:
    """Start the profiler only when the operator named an output file."""
    target = environ.get(PROFILE_ENV, "").strip()
    if not target:
        return None
    try:
        interval_ms = float(environ.get(INTERVAL_ENV, "") or DEFAULT_INTERVAL_MS)
    except ValueError:
        interval_ms = DEFAULT_INTERVAL_MS
    profiler = SamplingProfiler(Path(target).expanduser(), max(1.0, min(interval_ms, 1000.0)) / 1000)
    profiler.start()
    mode = "per-thread CPU" if profiler.measures_cpu else "wall clock"
    print(f"[orchestrator] sampling profiler writing {profiler.output} ({mode})", file=sys.stderr)
    return profiler
