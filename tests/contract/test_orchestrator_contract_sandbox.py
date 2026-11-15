"""The harness cleans up after a test process that never ran its cleanups (RR-509).

The reaper cases use throwaway processes in a private temporary directory, so
they run without a daemon build and never touch another checkout's sandboxes.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import orchestrator_contract_support as support
from orchestrator_contract_support import CONTRACT_DIR, DAEMON_CMD, ROOT_PREFIX, require_built


def _alive(pid: int) -> bool:
    return support.process_start(pid) != ""


def _wait_gone(pid: int, timeout: float = 20) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not _alive(pid):
            return True
        time.sleep(0.1)
    return False


class ReaperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = Path(os.path.realpath(tempfile.mkdtemp(prefix="relay-reaper-test-")))
        self.addCleanup(subprocess.run, ["/bin/rm", "-rf", str(self.temporary)], check=False)
        self.registry = self.temporary / (ROOT_PREFIX + "registry")
        self.registry.mkdir()

    def spawn_group(self) -> subprocess.Popen:
        """A stand-in daemon that leads its own group and has a child in it."""
        process = subprocess.Popen(
            ["/bin/sh", "-c", "/bin/sleep 300 & exec /bin/sleep 300"],
            start_new_session=True,
        )
        self.addCleanup(self._kill_group, process)
        return process

    @staticmethod
    def _kill_group(process: subprocess.Popen) -> None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        process.wait(timeout=20)

    def dead_owner(self):
        owner = subprocess.Popen(["/bin/sleep", "300"])
        start = support.process_start(owner.pid)
        owner.kill()
        owner.wait(timeout=20)
        return owner.pid, start

    def make_root(self, name: str) -> Path:
        root = self.temporary / (ROOT_PREFIX + name)
        (root / "state").mkdir(parents=True)
        return root

    def register(self, root: Path, owner, daemon=None, daemon_start=None) -> Path:
        entry = {"root": str(root), "owner_pid": owner[0], "owner_start": owner[1]}
        if daemon is not None:
            entry["daemon_pid"] = daemon.pid
            entry["daemon_start"] = daemon_start or support.process_start(daemon.pid)
        path = self.registry / (root.name + ".json")
        path.write_text(json.dumps(entry))
        return path

    def reap(self) -> list:
        return support.reap_stale_sandboxes(self.temporary, self.registry)

    def group_members(self, pgid: int) -> list:
        done = subprocess.run(["/usr/bin/pgrep", "-g", str(pgid)], capture_output=True, text=True)
        return done.stdout.split()

    def test_a_killed_test_process_leaves_no_daemon_after_the_next_start(self):
        root = self.make_root("killed")
        daemon = self.spawn_group()
        entry = self.register(root, self.dead_owner(), daemon)
        self.assertTrue(self.group_members(daemon.pid))

        self.assertEqual(self.reap(), [str(root)])

        self.assertIsNotNone(daemon.wait(timeout=20))
        self.assertTrue(self.wait_group_empty(daemon.pid), self.group_members(daemon.pid))
        self.assertFalse(root.exists())
        self.assertFalse(entry.exists())

    def wait_group_empty(self, pgid: int) -> bool:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if not self.group_members(pgid):
                return True
            time.sleep(0.1)
        return False

    def test_a_live_test_process_keeps_its_daemon_and_root(self):
        root = self.make_root("live")
        daemon = self.spawn_group()
        owner = (os.getpid(), support.process_start(os.getpid()))
        entry = self.register(root, owner, daemon)

        self.assertEqual(self.reap(), [])

        self.assertIsNone(daemon.poll())
        self.assertTrue(root.exists())
        self.assertTrue(entry.exists())

    def test_a_reused_daemon_pid_is_not_signalled(self):
        root = self.make_root("reused")
        bystander = self.spawn_group()
        self.register(root, self.dead_owner(), bystander, daemon_start="Thu Jan  1 00:00:00 1970")

        self.assertEqual(self.reap(), [str(root)])

        self.assertIsNone(bystander.poll())
        self.assertFalse(root.exists())

    def test_old_unregistered_roots_are_removed_and_young_ones_kept(self):
        old = self.make_root("old")
        young = self.make_root("young")
        unrelated = self.temporary / "something-else"
        unrelated.mkdir()
        stale = time.time() - support.UNREGISTERED_ROOT_MAX_AGE_SECONDS - 60
        for path in (old, unrelated):
            os.utime(str(path), (stale, stale))

        self.assertEqual(self.reap(), [str(old)])

        self.assertFalse(old.exists())
        self.assertTrue(young.exists())
        self.assertTrue(unrelated.exists())
        self.assertTrue(self.registry.exists())

    def test_read_only_snapshot_folders_are_removed(self):
        root = self.make_root("snapshot")
        snapshot = root / "workspaces" / "project-ct-1" / ".orchestrator"
        snapshot.mkdir(parents=True)
        (snapshot / "CT-1.md").write_text("ticket")
        (snapshot / "CT-1.md").chmod(0o444)
        snapshot.chmod(0o555)
        self.register(root, self.dead_owner())

        self.assertEqual(self.reap(), [str(root)])
        self.assertFalse(root.exists())

    def test_an_unreadable_entry_still_releases_its_root(self):
        root = self.make_root("broken")
        (self.registry / (root.name + ".json")).write_text("{not json")

        self.assertEqual(self.reap(), [str(root)])
        self.assertFalse(root.exists())
        self.assertEqual(list(self.registry.iterdir()), [])


# Starts a real sandbox daemon, reports it, then waits to be killed.
_CHILD = r"""
import json, sys, time
sys.path.insert(0, sys.argv[1])
from orchestrator_contract_support import Sandbox
box = Sandbox(lambda *arguments: None).start()
print(json.dumps({"root": str(box.root), "pid": box.process.pid,
                  "watchdog": box._watchdog.pid, "entry": str(box.registry_entry)}), flush=True)
time.sleep(600)
"""


class KilledSandboxTests(unittest.TestCase):
    """A test process killed mid-test with a real daemon running."""

    def setUp(self):
        require_built(DAEMON_CMD)

    def start_child(self) -> tuple:
        child = subprocess.Popen([sys.executable, "-c", _CHILD, str(CONTRACT_DIR)],
                                 stdout=subprocess.PIPE, text=True)
        self.addCleanup(child.wait, 20)
        self.addCleanup(child.kill)
        line = child.stdout.readline()
        child.stdout.close()
        self.assertTrue(line, "the child sandbox did not start")
        report = json.loads(line)
        self.addCleanup(self._last_resort, report["pid"])
        self.addCleanup(self._last_resort, report["watchdog"])
        return child, report

    @staticmethod
    def _last_resort(pgid: int) -> None:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    def test_the_watchdog_stops_the_daemon_and_the_next_start_removes_the_root(self):
        child, report = self.start_child()
        self.assertTrue(_alive(report["pid"]))

        child.kill()
        child.wait(timeout=20)

        self.assertTrue(_wait_gone(report["pid"]), "daemon outlived its test process")
        self.assertTrue(Path(report["root"]).exists())
        removed = support.reap_stale_sandboxes()
        self.assertIn(report["root"], removed)
        self.assertFalse(Path(report["root"]).exists())
        self.assertFalse(Path(report["entry"]).exists())

    def test_the_next_start_stops_a_daemon_the_watchdog_missed(self):
        child, report = self.start_child()
        pid = report["pid"]
        # Stand in for a watchdog that never ran: stop it, then kill the test process.
        os.kill(report["watchdog"], signal.SIGKILL)
        child.kill()
        child.wait(timeout=20)
        time.sleep(1)
        self.assertTrue(_alive(pid), "daemon should still be running before the reap")

        removed = support.reap_stale_sandboxes()

        self.assertIn(report["root"], removed)
        self.assertTrue(_wait_gone(pid))
        self.assertFalse(Path(report["root"]).exists())


if __name__ == "__main__":
    unittest.main()
