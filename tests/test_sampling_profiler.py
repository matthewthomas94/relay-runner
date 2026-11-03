from __future__ import annotations

import os
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

import sampling_profiler  # noqa: E402


def _busy_until(stop: threading.Event) -> None:
    total = 0
    while not stop.is_set():
        for value in range(10_000):
            total += value


class SamplingProfilerOffTests(unittest.TestCase):
    def test_unset_or_blank_variable_starts_no_thread_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            before = {thread.ident for thread in threading.enumerate()}
            for environ in ({}, {sampling_profiler.PROFILE_ENV: ""}, {sampling_profiler.PROFILE_ENV: "  "},
                            {sampling_profiler.INTERVAL_ENV: "5"}):
                cwd = os.getcwd()
                os.chdir(directory)
                try:
                    self.assertIsNone(sampling_profiler.start_from_environment(environ))
                finally:
                    os.chdir(cwd)
            after = {thread.ident for thread in threading.enumerate()}
            self.assertEqual(after, before)
            self.assertFalse(any(thread.name == "sampling-profiler" for thread in threading.enumerate()))
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_daemon_main_runs_without_a_profiler_by_default(self):
        import orchestrator

        seen = []

        def fake_serve(_daemon):
            seen.append([thread.name for thread in threading.enumerate()])

        environ = {key: value for key, value in os.environ.items() if key != sampling_profiler.PROFILE_ENV}
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.dict(os.environ, environ, clear=True), \
                mock.patch.object(orchestrator, "_parse_args", return_value=mock.Mock(config=None, print_port=False)), \
                mock.patch.object(orchestrator, "load_config", return_value={}), \
                mock.patch.object(orchestrator, "Daemon"), \
                mock.patch.object(orchestrator, "record_support_event"), \
                mock.patch.object(orchestrator, "serve", side_effect=fake_serve), \
                mock.patch.object(sampling_profiler.SamplingProfiler, "start") as start:
            cwd = os.getcwd()
            os.chdir(directory)
            try:
                orchestrator.main()
            finally:
                os.chdir(cwd)
            self.assertEqual(list(Path(directory).iterdir()), [])
        start.assert_not_called()
        self.assertEqual(len(seen), 1)
        self.assertNotIn("sampling-profiler", seen[0])


class SamplingProfilerOnTests(unittest.TestCase):
    def test_charges_busy_thread_and_skips_waiting_thread(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "daemon.folded"
            profiler = sampling_profiler.start_from_environment({
                sampling_profiler.PROFILE_ENV: str(output),
                sampling_profiler.INTERVAL_ENV: "5",
            })
            self.assertIsNotNone(profiler)
            stop = threading.Event()
            busy = threading.Thread(target=_busy_until, args=(stop,), name="busy-worker-7")
            idle = threading.Thread(target=stop.wait, name="idle-waiter")
            busy.start()
            idle.start()
            # Background-priority processes get coarse timers, so wait for
            # samples rather than for a fixed time.
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and sum(
                weight for stack, weight in profiler.snapshot().items() if stack.startswith("busy-worker-N;")
            ) < 100_000:
                time.sleep(0.05)
            stop.set()
            busy.join()
            idle.join()
            profiler.stop()
            lines = output.read_text().splitlines()
            self.assertFalse(any(path.name.endswith(".tmp") for path in Path(directory).iterdir()))
        stacks = {}
        for line in lines:
            stack, weight = line.rsplit(" ", 1)
            stacks[stack] = int(weight)
        busy_stacks = [stack for stack in stacks if stack.startswith("busy-worker-N;")]
        self.assertTrue(busy_stacks, lines)
        self.assertTrue(any(stack.endswith("test_sampling_profiler.py:_busy_until") for stack in busy_stacks))
        self.assertGreater(sum(stacks[stack] for stack in busy_stacks), 100_000)
        if profiler.measures_cpu:
            # Only its start-up CPU: waiting costs nothing.
            idle = sum(weight for stack, weight in stacks.items() if stack.startswith("idle-waiter;"))
            self.assertLess(idle, 10_000, lines)

    @unittest.skipUnless(sys.platform == "darwin", "per-thread CPU uses libproc")
    def test_darwin_reader_matches_thread_time(self):
        reader = sampling_profiler.darwin_thread_cpu_reader()
        self.assertIsNotNone(reader)
        native_id = threading.get_native_id()
        start, thread_start = reader(native_id), time.thread_time()
        _busy_until(_StopAfter(0.1))
        spent, thread_spent = reader(native_id) - start, time.thread_time() - thread_start
        self.assertAlmostEqual(spent, thread_spent, delta=0.01)


class _StopAfter:
    def __init__(self, seconds: float):
        self.deadline = time.monotonic() + seconds

    def is_set(self) -> bool:
        return time.monotonic() >= self.deadline


if __name__ == "__main__":
    unittest.main()
