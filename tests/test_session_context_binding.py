"""Exact provider/context bindings used by managed conversation recovery."""
from __future__ import annotations

import json
import fcntl
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services"))
import relay_completion_hook as hook


class SessionContextBindingTests(unittest.TestCase):
    def startup_fixture(self, root):
        transport, native = str(uuid.uuid4()), str(uuid.uuid4())
        destination = root / "bindings" / f"{transport}.json"
        destination.parent.mkdir()
        lock = root / "native" / "thread-writer-locks" / f"{native}.lock"
        lock.parent.mkdir(parents=True)
        lock.touch()
        identity = subprocess.run(["/bin/ps", "-p", str(os.getpid()), "-o", "lstart=", "-o", "uid=", "-o", "pgid="],
                                  capture_output=True, text=True, check=True).stdout.strip()
        record = {"schema_version": 1, "context_id": "general", "provider": "codex", "provider_session_id": transport,
                  "native_session_id": None, "transcript_path": None, "working_directory": str(Path.cwd().resolve()),
                  "provider_pid": os.getpid(), "provider_process_identity": identity}
        destination.write_text(json.dumps(record))
        mapped = subprocess.run(["/usr/sbin/lsof", "-n", "-P", "-a", "-p", str(os.getpid()), "-d", "txt", "-Fn"],
                                capture_output=True, text=True, check=True).stdout
        binary = next(line[1:] for line in mapped.splitlines() if line.startswith("n"))
        env = {"RELAY_SESSION_BINDING_PATH": str(destination), "RELAY_CONTEXT_ID": "general",
               "RELAY_PROVIDER_SESSION_ID": transport, "RELAY_CONTEXT_WORKING_DIRECTORY": record["working_directory"],
               "RELAY_RUNNER_PROVIDER": "codex", "RELAY_PROVIDER_PROCESS_ID": str(os.getpid()),
               "RELAY_PROVIDER_BINARY": binary, "CODEX_HOME": str(root / "native")}
        files = f"p{os.getpid()}\nfcwd\nn{record['working_directory']}\nftxt\nn{binary}\nf9\nn{lock}\n"
        return destination, lock, record, env, files, native

    def test_zero_turn_native_identity_uses_real_owned_writer_lock_and_enriches_without_work(self):
        with tempfile.TemporaryDirectory() as temp:
            destination, lock, record, env, _, native = self.startup_fixture(Path(temp).resolve())
            with lock.open("rb") as writer, patch.dict(os.environ, env):
                fcntl.flock(writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
                # Exercise real ps/lsof/flock and publication, before any native
                # user turn or transcript exists. The configured executable is
                # this controlled test process, not a newest-session heuristic.
                self.assertTrue(hook.record_codex_startup_binding(wait_seconds=0))
                binding = json.loads(destination.read_text())
                self.assertEqual(binding["native_session_id"], native)
                self.assertEqual(binding["provider_process_identity"], record["provider_process_identity"])
                self.assertIsNone(binding["transcript_path"])
                transcript = str(Path(temp) / f"{native}.jsonl")
                self.assertTrue(hook.record_session_binding({"session_id": native, "cwd": record["working_directory"], "transcript_path": transcript}))
                enriched = destination.read_bytes()
                self.assertTrue(hook.record_codex_startup_binding(wait_seconds=0))
                self.assertEqual(destination.read_bytes(), enriched, "Startup observation never clobbers richer lifecycle state")

    def test_startup_binding_fails_closed_for_missing_multiple_foreign_or_unheld_writer(self):
        for failure in ("missing", "multiple", "foreign", "unheld", "cwd", "binary", "initial_birth", "final_birth", "sidecar_changed", "lsof_failed"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temp:
                destination, lock, record, env, files, _ = self.startup_fixture(Path(temp).resolve())
                if failure == "missing":
                    files = files[:files.index("f9\n")]
                elif failure == "multiple":
                    files += f"f10\nn{lock.parent / (str(uuid.uuid4()) + '.lock')}\n"
                elif failure == "foreign":
                    files = files.replace(str(lock), str(Path(temp) / lock.name))
                elif failure == "cwd":
                    files = files.replace("fcwd\nn" + record["working_directory"], "fcwd\nn/different")
                elif failure == "binary":
                    files = files.replace(env["RELAY_PROVIDER_BINARY"], "/different/native")
                calls = 0
                def observe(command, **kwargs):
                    nonlocal calls
                    if command[0] == "/bin/ps":
                        calls += 1
                        identity = record["provider_process_identity"]
                        if failure == "initial_birth" or failure == "final_birth" and calls > 1:
                            identity = "reused PID with a different birth"
                        return subprocess.CompletedProcess(command, 0, identity, "")
                    if failure == "sidecar_changed":
                        changed = dict(record, context_id="project:elsewhere")
                        destination.write_text(json.dumps(changed))
                    return subprocess.CompletedProcess(command, 1 if failure == "lsof_failed" else 0, files, "")
                with lock.open("rb") as writer, patch.dict(os.environ, env), patch.object(hook.subprocess, "run", side_effect=observe):
                    if failure != "unheld":
                        fcntl.flock(writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    self.assertFalse(hook.record_codex_startup_binding(wait_seconds=0))
                self.assertIsNone(json.loads(destination.read_text())["native_session_id"])

    def test_startup_compare_and_swap_cannot_overwrite_a_native_hook_winner(self):
        with tempfile.TemporaryDirectory() as temp:
            destination, _, record, env, _, native = self.startup_fixture(Path(temp).resolve())
            with patch.dict(os.environ, env):
                self.assertTrue(hook.record_session_binding({"session_id": native, "cwd": record["working_directory"], "transcript_path": "/exact/transcript"}))
                winner = destination.read_bytes()
                self.assertFalse(hook.record_session_binding({"session_id": str(uuid.uuid4()), "cwd": record["working_directory"]}, expected_binding=record))
                self.assertEqual(destination.read_bytes(), winner)

    def test_both_providers_bind_exact_identity_without_conversation_contents(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                transport, native = str(uuid.uuid4()), str(uuid.uuid4())
                destination = root / "bindings" / f"{transport}.json"
                env = {
                    "RELAY_SESSION_BINDING_PATH": str(destination),
                    "RELAY_CONTEXT_ID": "general",
                    "RELAY_PROVIDER_SESSION_ID": transport,
                    "RELAY_CONTEXT_WORKING_DIRECTORY": temp,
                    "RELAY_RUNNER_PROVIDER": provider,
                }
                with patch.dict(os.environ, env, clear=True):
                    hook.record_session_binding({"session_id": native, "cwd": temp,
                                                 "transcript_path": f"/provider/{native}.jsonl",
                                                 "prompt": "must not be copied", "thinking": "private"})
                record = json.loads(destination.read_text())
                self.assertEqual(record["context_id"], "general")
                self.assertEqual(record["provider"], provider)
                self.assertEqual(record["provider_session_id"], transport)
                self.assertEqual(record["native_session_id"], native)
                self.assertEqual(record["working_directory"], str(root.resolve()))
                self.assertNotIn("must not be copied", destination.read_text())
                self.assertNotIn("thinking", record)
                self.assertNotIn("prompt", record)
                self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
                self.assertEqual(list(destination.parent.glob("*.tmp")), [])

    def test_wrong_cwd_or_invalid_identity_or_wrong_binding_filename_cannot_bind(self):
        for failure in ("cwd", "native", "transport", "filename", "parent", "provider"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temp:
                transport, native = str(uuid.uuid4()), str(uuid.uuid4())
                destination = Path(temp) / "bindings" / f"{transport}.json"
                env = {
                    "RELAY_SESSION_BINDING_PATH": str(destination), "RELAY_CONTEXT_ID": "project:confirmed",
                    "RELAY_PROVIDER_SESSION_ID": transport,
                    "RELAY_CONTEXT_WORKING_DIRECTORY": temp, "RELAY_RUNNER_PROVIDER": "codex",
                }
                payload = {"session_id": native, "cwd": temp}
                if failure == "cwd":
                    payload["cwd"] = "/different/repository"
                elif failure == "native":
                    payload["session_id"] = "not-a-native-uuid"
                elif failure == "transport":
                    env["RELAY_PROVIDER_SESSION_ID"] = "not-a-transport-uuid"
                elif failure == "filename":
                    env["RELAY_SESSION_BINDING_PATH"] = str(destination.with_name("different.json"))
                elif failure == "parent":
                    env["RELAY_SESSION_BINDING_PATH"] = str(Path(temp) / f"{transport}.json")
                else:
                    env["RELAY_RUNNER_PROVIDER"] = "unsupported"
                with patch.dict(os.environ, env, clear=True):
                    hook.record_session_binding(payload)
                self.assertEqual(list(Path(temp).rglob("*.json")), [])

    def test_ordinary_unmanaged_hook_does_not_create_a_binding(self):
        with patch.dict(os.environ, {}, clear=True):
            hook.record_session_binding({"session_id": str(uuid.uuid4()), "cwd": "/some/repo"})

    def test_launch_records_its_live_process_before_provider_hooks_exist(self):
        with tempfile.TemporaryDirectory() as temp:
            transport = str(uuid.uuid4())
            destination = Path(temp) / "bindings" / f"{transport}.json"
            env = dict(os.environ, RELAY_SESSION_BINDING_PATH=str(destination), RELAY_CONTEXT_ID="general",
                       RELAY_PROVIDER_SESSION_ID=transport, RELAY_CONTEXT_WORKING_DIRECTORY=temp,
                       RELAY_RUNNER_PROVIDER="codex", BINDING_HOOK=hook.__file__)
            result = subprocess.run(["/bin/bash", "-c", 'export RELAY_PROVIDER_PROCESS_ID=$$; /usr/bin/python3 "$BINDING_HOOK" --record-process; status=$?; exit "$status"'],
                                    env=env, cwd=temp, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            record = json.loads(destination.read_text())
            self.assertIsNone(record["native_session_id"])
            self.assertGreater(record["provider_pid"], 1)
            self.assertTrue(record["provider_process_identity"])
            self.assertEqual(result.stdout, "")

    def test_process_binding_fails_closed_without_exact_parent_ownership(self):
        with tempfile.TemporaryDirectory() as temp:
            transport = str(uuid.uuid4())
            destination = Path(temp) / "bindings" / f"{transport}.json"
            env = {"RELAY_SESSION_BINDING_PATH": str(destination), "RELAY_CONTEXT_ID": "general",
                   "RELAY_PROVIDER_SESSION_ID": transport, "RELAY_CONTEXT_WORKING_DIRECTORY": temp,
                   "RELAY_RUNNER_PROVIDER": "claude", "RELAY_PROVIDER_PROCESS_ID": "2"}
            with patch.dict(os.environ, env, clear=True):
                with self.assertRaises(ValueError):
                    hook.record_session_binding({"cwd": temp}, process_only=True)
            self.assertFalse(destination.exists())

    def test_process_capture_fails_closed_for_missing_launch_identity(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(sys, "argv", [hook.__file__, "--record-process"]):
            self.assertEqual(hook.main(), 1)


if __name__ == "__main__":
    unittest.main()
