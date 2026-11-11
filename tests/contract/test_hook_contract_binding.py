"""Session binding contract: lifecycle events, `--record-process` and
`--record-codex-startup`.

The binding file ties one app launch to the provider's native session. The
launcher records the provider process first, Codex's startup watcher adds the
native session it finds, and every lifecycle event rewrites the binding with
the session and transcript the provider reports.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import unittest

from hook_contract_support import ContractCase, process_identity, stop_process

NATIVE_FROM_LOCK = "9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a"
# Holds an exclusive lock on its first argument until stdin closes.
LOCK_HOLDER = (
    "import fcntl, sys\n"
    "handle = open(sys.argv[1], 'rb') if len(sys.argv) > 1 else None\n"
    "if handle: fcntl.flock(handle, fcntl.LOCK_EX)\n"
    "print('ready', flush=True)\n"
    "sys.stdin.read()\n"
)


def exited_pid() -> int:
    process = subprocess.Popen(["/usr/bin/true"])
    process.wait()
    return process.pid


class BindingCase(ContractCase):
    def binding(self, **fields) -> dict:
        box = self.box
        binding = {
            "schema_version": 1,
            "context_id": box.CONTEXT_ID,
            "provider": self.provider,
            "provider_session_id": box.PROVIDER_SESSION_ID,
            "native_session_id": box.NATIVE_SESSION_ID,
            "working_directory": str(box.workdir),
            "transcript_path": str(box.transcript_path),
        }
        binding.update(fields)
        return binding

    def process_binding(self, pid: int, **fields) -> dict:
        """What `--record-process` leaves for the provider process `pid`."""
        return self.binding(
            native_session_id=None, transcript_path=None,
            provider_pid=pid, provider_process_identity=process_identity(pid), **fields
        )

    def write_binding(self, binding: dict) -> None:
        self.box.binding_path.parent.mkdir(exist_ok=True)
        self.box.binding_path.write_text(json.dumps(binding, sort_keys=True))

    def assertBinding(self, expected: dict) -> None:
        box = self.box
        self.assertEqual(box.read_json(box.binding_path), expected)
        self.assertEqual(box.mode(box.binding_path), 0o600)
        self.assertEqual(box.mode(box.binding_path.parent), 0o700)
        lock = box.binding_path.with_suffix(".lock")
        self.assertEqual(sorted(path.name for path in box.binding_path.parent.iterdir()),
                         [box.binding_path.name, lock.name])
        self.assertEqual(box.mode(lock), 0o600)

    def assertNoBinding(self) -> None:
        self.assertFalse(self.box.binding_path.parent.exists())


class LifecycleBindingContract:
    """Every lifecycle event carries the native session to the binding file."""

    def first_event(self, **fields) -> dict:
        return self.box.payload("UserPromptSubmit", prompt="typed by hand", **fields)

    def test_lifecycle_event_binds_the_native_session(self):
        box = self.box
        result = box.hook(self.first_event(), env=box.binding_env())
        self.assertQuietSuccess(result)
        self.assertBinding(self.binding())

    def test_binding_names_the_live_provider_process(self):
        box = self.box
        env = box.binding_env(RELAY_PROVIDER_PROCESS_ID=os.getpid())
        self.assertQuietSuccess(box.hook(self.first_event(), env=env))
        self.assertBinding(self.binding(
            provider_pid=os.getpid(), provider_process_identity=process_identity(os.getpid()),
        ))

    def test_binding_omits_a_provider_process_that_is_not_running(self):
        for process_id in (exited_pid(), "1", "0", "not-a-pid", ""):
            with self.subTest(process_id=process_id):
                self.setUp()
                env = self.box.binding_env(RELAY_PROVIDER_PROCESS_ID=process_id)
                self.assertQuietSuccess(self.box.hook(self.first_event(), env=env))
                self.assertBinding(self.binding())

    def test_every_event_rewrites_the_binding(self):
        box = self.box
        env = box.binding_env(RELAY_PROVIDER_PROCESS_ID=os.getpid())
        self.write_binding(self.process_binding(os.getpid()))
        for event in ("UserPromptSubmit", "Stop", "PreCompact", "PostCompact", "Notification"):
            with self.subTest(event):
                transcript = str(box.root / (event + ".jsonl"))
                payload = box.payload(event, transcript_path=transcript)
                self.assertQuietSuccess(box.hook(payload, env=env))
                self.assertEqual(box.read_json(box.binding_path), self.binding(
                    transcript_path=transcript,
                    provider_pid=os.getpid(), provider_process_identity=process_identity(os.getpid()),
                ))

    def test_binding_does_not_need_foreground_ownership(self):
        box = self.box
        env = box.binding_env(RELAY_ACTOR_ROLE="voice_bridge")
        self.assertQuietSuccess(box.hook(self.first_event(), env=env))
        self.assertBinding(self.binding())

    def test_event_without_a_transcript_binds_a_null_transcript(self):
        box = self.box
        payload = self.first_event()
        del payload["transcript_path"]
        self.assertQuietSuccess(box.hook(payload, env=box.binding_env()))
        self.assertBinding(self.binding(transcript_path=None))

    def test_event_without_a_cwd_is_checked_against_the_process_directory(self):
        box = self.box
        payload = self.first_event()
        del payload["cwd"]
        self.assertQuietSuccess(box.hook(payload, env=box.binding_env(), cwd=box.root))
        self.assertNoBinding()
        self.assertQuietSuccess(box.hook(payload, env=box.binding_env(), cwd=box.workdir))
        self.assertBinding(self.binding())

    def test_working_directory_is_compared_after_resolving_links(self):
        box = self.box
        link = box.root / "project-link"
        link.symlink_to(box.workdir)
        env = box.binding_env(RELAY_CONTEXT_WORKING_DIRECTORY=str(link))
        self.assertQuietSuccess(box.hook(self.first_event(), env=env))
        self.assertBinding(self.binding())

    def test_event_that_does_not_match_the_launch_is_not_bound(self):
        box = self.box
        other = box.root / "bindings" / "other.json"
        cases = (
            ("native session is not a UUID", {}, {"session": "startup-session"}),
            ("another working directory", {}, {"cwd": str(box.root)}),
            ("no binding path", {"RELAY_SESSION_BINDING_PATH": None}, {}),
            ("no context", {"RELAY_CONTEXT_ID": None}, {}),
            ("no expected working directory", {"RELAY_CONTEXT_WORKING_DIRECTORY": None}, {}),
            ("unsupported provider", {"RELAY_RUNNER_PROVIDER": "other"}, {}),
            ("no provider", {"RELAY_RUNNER_PROVIDER": None}, {}),
            ("provider session is not a UUID", {"RELAY_PROVIDER_SESSION_ID": "session-1"}, {}),
            ("file not named for the provider session", {"RELAY_SESSION_BINDING_PATH": str(other)}, {}),
            ("file outside a bindings directory",
             {"RELAY_SESSION_BINDING_PATH": str(box.root / (box.PROVIDER_SESSION_ID + ".json"))}, {}),
        )
        for name, overrides, fields in cases:
            with self.subTest(name):
                self.assertQuietSuccess(box.hook(self.first_event(**fields), env=box.binding_env(**overrides)))
                self.assertNoBinding()
                self.assertEqual([p for p in box.tree() if p.endswith((".json", ".lock", ".tmp"))], [])

    def test_unbindable_event_is_still_handled(self):
        box = self.box
        box.claim()
        payload = box.payload("UserPromptSubmit", prompt="ship the release notes", cwd=str(box.root))
        self.assertQuietSuccess(box.hook(payload, env=box.binding_env()))
        self.assertNoBinding()
        self.assertEqual([row["state"] for row in box.rows("provider_turns")], ["active"])


class RecordProcessContract:
    """`--record-process`: the launcher records the process it is about to become."""

    def record_process(self, *, cwd=None, **overrides):
        box = self.box
        overrides.setdefault("RELAY_PROVIDER_PROCESS_ID", os.getpid())
        result = box.hook(b"", "--record-process", env=box.binding_env(**overrides), cwd=cwd)
        self.assertEqual(result.stdout, b"")
        return result

    def test_record_process_binds_the_parent_process(self):
        result = self.record_process()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertBinding(self.process_binding(os.getpid()))
        self.assertEqual(self.box.fifo_lines(), [])
        self.assertFalse(self.box.inbox_path.exists())

    def test_record_process_ignores_stdin(self):
        box = self.box
        payload = box.payload("UserPromptSubmit", prompt="typed by hand")
        result = box.hook(payload, "--record-process", env=box.binding_env(RELAY_PROVIDER_PROCESS_ID=os.getpid()))
        self.assertEqual((result.returncode, result.stdout), (0, b""))
        self.assertBinding(self.process_binding(os.getpid()))

    def test_record_process_replaces_an_earlier_binding(self):
        self.write_binding(self.binding(context_id="an earlier context"))
        self.assertEqual(self.record_process().returncode, 0)
        self.assertEqual(self.box.read_json(self.box.binding_path), self.process_binding(os.getpid()))

    def test_record_process_refuses_a_process_that_is_not_its_parent(self):
        bystander = subprocess.Popen([sys.executable, "-c", LOCK_HOLDER], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(stop_process, bystander)
        bystander.stdout.readline()
        for process_id in (bystander.pid, exited_pid(), "1", "not-a-pid", "", None):
            with self.subTest(process_id=process_id):
                result = self.record_process(RELAY_PROVIDER_PROCESS_ID=process_id)
                self.assertEqual(result.returncode, 1)
                self.assertNoBinding()

    def test_record_process_refuses_a_launch_it_cannot_identify(self):
        box = self.box
        cases = (
            ("another working directory", {}, box.root),
            ("no binding path", {"RELAY_SESSION_BINDING_PATH": None}, None),
            ("no context", {"RELAY_CONTEXT_ID": None}, None),
            ("no expected working directory", {"RELAY_CONTEXT_WORKING_DIRECTORY": None}, None),
            ("unsupported provider", {"RELAY_RUNNER_PROVIDER": "other"}, None),
            ("provider session is not a UUID", {"RELAY_PROVIDER_SESSION_ID": "session-1"}, None),
            ("no provider session", {"RELAY_PROVIDER_SESSION_ID": None}, None),
            ("file not named for the provider session",
             {"RELAY_SESSION_BINDING_PATH": str(box.root / "bindings" / "other.json")}, None),
        )
        for name, overrides, cwd in cases:
            with self.subTest(name):
                result = self.record_process(cwd=cwd, **overrides)
                self.assertEqual(result.returncode, 1)
                self.assertNoBinding()


class ClaudeBinding(LifecycleBindingContract, RecordProcessContract, BindingCase):
    provider = "claude"

    def first_event(self, **fields) -> dict:
        return self.box.payload("SessionStart", source="startup", **fields)

    def test_session_start_binds_and_records_the_first_run_boundary(self):
        box = self.box
        self.assertQuietSuccess(box.hook(self.first_event(), env=box.binding_env()))
        self.assertBinding(self.binding())
        self.assertEqual([e["stage"] for e in box.jsonl(box.session_events_path)], ["provider_session_start"])

    def test_startup_watcher_is_not_available_for_claude(self):
        box = self.box
        self.write_binding(self.process_binding(os.getpid()))
        env = box.binding_env(RELAY_PROVIDER_PROCESS_ID=os.getpid(), RELAY_PROVIDER_BINARY=sys.executable)
        result = box.hook(b"", "--record-codex-startup", env=env, timeout=10)
        self.assertEqual((result.returncode, result.stdout), (1, b""))
        self.assertEqual(box.read_json(box.binding_path), self.process_binding(os.getpid()))


class CodexBinding(LifecycleBindingContract, RecordProcessContract, BindingCase):
    provider = "codex"

    # -- --record-codex-startup ----------------------------------------------

    def start_provider(self, *, lock_name=NATIVE_FROM_LOCK + ".lock", cwd=None) -> subprocess.Popen:
        """A stand-in Codex process, holding its thread writer lock if named."""
        arguments = [sys.executable, "-c", LOCK_HOLDER]
        if lock_name:
            locks = self.box.codex_home / "thread-writer-locks"
            locks.mkdir(parents=True, exist_ok=True)
            (locks / lock_name).write_bytes(b"")
            arguments.append(str(locks / lock_name))
        provider = subprocess.Popen(
            arguments, cwd=str(cwd or self.box.workdir), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        )
        self.addCleanup(stop_process, provider)
        self.assertEqual(provider.stdout.readline(), b"ready\n")
        return provider

    def startup_env(self, provider: subprocess.Popen, **overrides) -> dict:
        binary = subprocess.run(
            ["/bin/ps", "-p", str(provider.pid), "-o", "comm="], capture_output=True, text=True, check=True,
        ).stdout.strip()
        values = {"RELAY_PROVIDER_PROCESS_ID": provider.pid, "RELAY_PROVIDER_BINARY": binary}
        values.update(overrides)
        return self.box.binding_env(**values)

    def watch(self, env: dict, *, timeout: float = 30):
        result = self.box.hook(b"", "--record-codex-startup", env=env, timeout=timeout)
        self.assertEqual(result.stdout, b"")
        return result

    def test_startup_watcher_binds_the_session_of_the_held_writer_lock(self):
        provider = self.start_provider()
        before = self.process_binding(provider.pid)
        self.write_binding(before)
        result = self.watch(self.startup_env(provider))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.box.read_json(self.box.binding_path), dict(before, native_session_id=NATIVE_FROM_LOCK))
        self.assertEqual(self.box.mode(self.box.binding_path), 0o600)
        self.assertEqual(self.box.fifo_lines(), [])

    def test_startup_watcher_leaves_a_binding_a_lifecycle_event_already_enriched(self):
        provider = self.start_provider(lock_name=None)
        enriched = dict(self.process_binding(provider.pid), native_session_id=self.box.NATIVE_SESSION_ID,
                        transcript_path=str(self.box.transcript_path))
        self.write_binding(enriched)
        self.assertEqual(self.watch(self.startup_env(provider)).returncode, 0)
        self.assertEqual(self.box.read_json(self.box.binding_path), enriched)

    def test_startup_watcher_stops_when_a_lifecycle_event_enriches_the_binding(self):
        box = self.box
        provider = self.start_provider(lock_name=None)
        self.write_binding(self.process_binding(provider.pid))
        env = self.startup_env(provider)
        watcher = box.start_hook("--record-codex-startup", env=env)
        time.sleep(0.5)
        self.assertIsNone(watcher.poll())
        self.assertQuietSuccess(box.hook(box.payload("UserPromptSubmit", prompt="typed by hand"), env=env))
        self.assertEqual(watcher.wait(timeout=30), 0)
        self.assertEqual(box.read_json(box.binding_path), dict(
            self.process_binding(provider.pid), native_session_id=box.NATIVE_SESSION_ID,
            transcript_path=str(box.transcript_path),
        ))

    def test_startup_watcher_gives_up_when_the_provider_exits(self):
        box = self.box
        provider = self.start_provider(lock_name=None)
        before = self.process_binding(provider.pid)
        self.write_binding(before)
        watcher = box.start_hook("--record-codex-startup", env=self.startup_env(provider))
        time.sleep(0.5)
        self.assertIsNone(watcher.poll())
        stop_process(provider)
        self.assertEqual(watcher.wait(timeout=30), 1)
        self.assertEqual(watcher.stdout.read(), b"")
        self.assertEqual(box.read_json(box.binding_path), before)

    def test_startup_watcher_gives_up_when_the_binding_is_replaced(self):
        box = self.box
        provider = self.start_provider(lock_name=None)
        self.write_binding(self.process_binding(provider.pid))
        watcher = box.start_hook("--record-codex-startup", env=self.startup_env(provider))
        time.sleep(0.5)
        self.assertIsNone(watcher.poll())
        replaced = self.process_binding(provider.pid, context_id="another context")
        self.write_binding(replaced)
        self.assertEqual(watcher.wait(timeout=30), 1)
        self.assertEqual(box.read_json(box.binding_path), replaced)

    def test_startup_watcher_refuses_a_lock_that_does_not_name_a_session(self):
        provider = self.start_provider(lock_name="not-a-session.lock")
        before = self.process_binding(provider.pid)
        self.write_binding(before)
        self.assertEqual(self.watch(self.startup_env(provider)).returncode, 1)
        self.assertEqual(self.box.read_json(self.box.binding_path), before)

    def test_startup_watcher_refuses_a_launch_it_cannot_identify(self):
        box = self.box
        provider = self.start_provider()
        recorded = self.process_binding(provider.pid)
        cases = (
            ("no binding", None, {}),
            ("binding without a process", self.binding(native_session_id=None, transcript_path=None), {}),
            ("binding for another process", recorded, {"RELAY_PROVIDER_PROCESS_ID": os.getpid()}),
            ("binding for another provider", dict(recorded, provider="claude"), {}),
            ("binding for another provider session", dict(recorded, provider_session_id="other"), {}),
            ("binding for another context", dict(recorded, context_id="another context"), {}),
            ("binding for another directory", dict(recorded, working_directory=str(box.root)), {}),
            ("process identity changed", dict(recorded, provider_process_identity="Mon Jan  1 00:00:00 2001 0 0"), {}),
            ("relative provider binary", recorded, {"RELAY_PROVIDER_BINARY": "codex"}),
            ("no provider binary", recorded, {"RELAY_PROVIDER_BINARY": None}),
            ("no binding path", recorded, {"RELAY_SESSION_BINDING_PATH": None}),
        )
        for name, binding, overrides in cases:
            with self.subTest(name):
                if binding is None:
                    self.assertNoBinding()
                else:
                    self.write_binding(binding)
                result = self.watch(self.startup_env(provider, **overrides), timeout=10)
                self.assertEqual(result.returncode, 1)
                if binding is not None:
                    self.assertEqual(box.read_json(box.binding_path), binding)

    def test_startup_watcher_refuses_a_provider_that_already_exited(self):
        provider = self.start_provider()
        before = self.process_binding(provider.pid)
        self.write_binding(before)
        env = self.startup_env(provider)
        stop_process(provider)
        self.assertEqual(self.watch(env, timeout=10).returncode, 1)
        self.assertEqual(self.box.read_json(self.box.binding_path), before)


if __name__ == "__main__":
    unittest.main()
