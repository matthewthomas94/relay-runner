"""RR-490: the messenger's provider backends served by `relay-rs messenger`.

The selection tests always run. The rest drive the built helper
(`RELAY_RS_BINARY`, or `rust/target/{debug,release}/relay-rs`) against the
voice-bridge contract suite's scripted `claude` and `codex`, and compare its
model and effort resolution with the Python backends'."""

from __future__ import annotations

import json
import os
import shlex
import sys
import tempfile
import threading
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "services"))

from messenger import (  # noqa: E402
    ClaudeMessengerBackend,
    MessengerConfig,
    MessengerError,
    create_messenger_runtime,
    resolve_messenger_catalog_selection,
)
from rust_messenger import RustMessengerBackend, rust_backend_requested, rust_binary  # noqa: E402

FAKE_MESSENGER = ROOT / "tests" / "contract" / "fakes" / "messenger.py"
CODEX_MODELS = json.dumps({"data": [
    {"id": "gpt-6-sol", "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"],
     "defaultReasoningEffort": "medium"},
    {"id": "gpt-6-luna", "supportedReasoningEfforts": ["low", "medium", "high"],
     "defaultReasoningEffort": "low"},
    {"id": "gpt-6.1-luna", "hidden": True},
    {"id": "gpt-6-astra", "supportedReasoningEfforts": ["low", "high", "max", "ultra"]},
]})


def built_helper() -> str | None:
    for candidate in (os.environ.get("RELAY_RS_BINARY", ""),
                      str(ROOT / "rust" / "target" / "debug" / "relay-rs"),
                      str(ROOT / "rust" / "target" / "release" / "relay-rs")):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return None


class SelectionTests(unittest.TestCase):
    def test_only_rust_selects_the_rust_backends(self):
        self.assertTrue(rust_backend_requested({"RELAY_MESSENGER_RUNTIME": " Rust "}))
        for value in ("", "python", "1"):
            self.assertFalse(rust_backend_requested({"RELAY_MESSENGER_RUNTIME": value}))
        self.assertFalse(rust_backend_requested({}))

    def test_the_helper_must_be_executable(self):
        self.assertEqual(rust_binary({"RELAY_RS_BINARY": "/bin/sh"}), "/bin/sh")
        self.assertIsNone(rust_binary({"RELAY_RS_BINARY": "/nonexistent/relay-rs"}))

    def test_a_missing_helper_keeps_the_python_backends(self):
        with tempfile.TemporaryDirectory() as folder:
            claude = Path(folder) / "claude"
            claude.write_text("#!/bin/sh\n")
            claude.chmod(0o755)
            config = {"general": {"provider": "claude", "command": str(claude)}}
            with patch.dict(os.environ, {"RELAY_MESSENGER_RUNTIME": "rust",
                                         "RELAY_RS_BINARY": "/nonexistent/relay-rs"}):
                runtime = create_messenger_runtime(config, speak=lambda *a, **k: True,
                                                   is_current=lambda *a: True, cwd=folder)
            self.assertIsInstance(runtime.backend, ClaudeMessengerBackend)


@unittest.skipUnless(built_helper(), "relay-rs is not built")
class RustBackendTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(prefix="rr490-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(self.folder, ignore_errors=True))
        self.log = self.folder / "messenger.jsonl"
        self.script = self.folder / "script.json"
        self.script.write_text(json.dumps({"rules": []}))
        for provider in ("claude", "codex"):
            wrapper = self.folder / provider
            wrapper.write_text("#!/bin/sh\n" f"exec {shlex.quote(sys.executable)} "
                               f"{shlex.quote(str(FAKE_MESSENGER))} {provider} \"$@\"\n")
            wrapper.chmod(0o755)
        environment = patch.dict(os.environ, {
            "RELAY_CONTRACT_MESSENGER_LOG": str(self.log),
            "RELAY_CONTRACT_MESSENGER_SCRIPT": str(self.script),
            "RELAY_CODEX_MODEL_LIST_JSON": CODEX_MODELS,
            "RELAY_PROVIDER_SESSION_ID": "foreground-only",
        })
        environment.start()
        self.addCleanup(environment.stop)

    def backend(self, **general) -> RustMessengerBackend:
        general.setdefault("command", str(self.folder / general.get("provider", "codex")))
        backend = RustMessengerBackend(built_helper(), general, str(self.folder), error_type=MessengerError)
        self.addCleanup(self.close, backend)
        return backend

    @staticmethod
    def close(backend: RustMessengerBackend) -> None:
        backend.shutdown()
        helper = backend._proc
        if helper is not None:
            helper.stdin.close()  # end of input: the helper exits
            helper.wait(timeout=5)
            helper.stdout.close()

    def claude_launches(self, count: int) -> list:
        """The first `count` stream-json launches, once the fake has logged them."""
        while True:
            launches = [r["argv"] for r in self.records("launch") if r["argv"][:1] == ["--print"]]
            if len(launches) >= count:
                return launches
            threading.Event().wait(0.02)

    def wait_for_prompt(self) -> None:
        while not self.records("prompt"):
            threading.Event().wait(0.02)
        threading.Event().wait(0.3)  # the helper has taken the turn id

    def records(self, kind: str) -> list:
        if not self.log.exists():
            return []
        return [r for r in map(json.loads, self.log.read_text().splitlines()) if r["record"] == kind]

    def test_model_and_effort_resolve_as_the_python_backends_do(self):
        selections = [
            {},
            {"messenger_model": "sol", "messenger_effort": "xhigh"},
            {"messenger_model": "gpt-6-astra", "messenger_effort": "ultra"},
            {"messenger_model": "mystery", "messenger_effort": "high"},
            {"provider": "claude"},
            {"provider": "claude", "messenger_model": "sonnet", "messenger_effort": "max"},
            {"provider": "claude", "messenger_model": "haiku", "messenger_effort": "high"},
        ]
        for selection in selections:
            with self.subTest(selection=selection):
                general = {"provider": "codex", **selection}
                general["command"] = str(self.folder / general["provider"])
                expected = MessengerConfig.from_app_config({"general": general}, cwd=self.folder)
                expected = resolve_messenger_catalog_selection(
                    replace(expected, command=shlex.join([str(self.folder / general["provider"])])))
                self.assertEqual(self.backend(**general).config, expected)

    def test_an_unadvertised_codex_effort_leaves_the_messenger_unavailable(self):
        backend = self.backend(messenger_model="luna", messenger_effort="xhigh")
        with self.assertRaisesRegex(MessengerError, "messenger model selection is unavailable"):
            backend.ask("hello", timeout=5)

    def test_codex_answers_with_its_first_sentence_early(self):
        backend = self.backend()
        partials: list = []
        prompt = "Current event: user_turn\nCurrent event content:\nlook at the build\nReturn only "
        text = backend.ask(prompt, timeout=10, on_partial=partials.append)
        self.assertEqual(text, "__HANDOFF__ Messenger heard: look at the build")
        self.assertEqual(partials, ["__HANDOFF__ Messenger heard: look at the build"])
        thread = self.records("thread")[0]["params"]
        self.assertEqual((thread["model"], thread["sandbox"], thread["ephemeral"]),
                         ("gpt-6-luna", "read-only", True))
        launch = [r for r in self.records("launch") if "features.hooks=false" in r["argv"]][0]
        self.assertEqual(launch["env"], {"RELAY_ACTOR_ROLE": "messenger"})

    def test_a_helper_that_died_is_restarted_with_the_same_configuration(self):
        backend = self.backend(messenger_model="sol", messenger_effort="high")
        backend._proc.kill()
        backend._proc.wait(timeout=5)
        prompt = "Current event: user_turn\nCurrent event content:\nare you back\nReturn only "
        self.assertEqual(backend.ask(prompt, timeout=10), "__HANDOFF__ Messenger heard: are you back")
        self.assertEqual(self.records("thread")[0]["params"]["model"], "gpt-6-sol")

    def test_an_interrupted_codex_turn_is_interrupted_on_its_thread(self):
        self.script.write_text(json.dumps({"rules": [{"when": "slow", "reply": "late", "delay": 5}]}))
        backend = self.backend()
        backend.start()
        answer: list = []
        prompt = "Current event: user_turn\nCurrent event content:\nslow\nReturn only "
        worker = threading.Thread(target=lambda: answer.append(backend.ask(prompt, timeout=10)))
        worker.start()
        self.wait_for_prompt()
        backend.interrupt()
        worker.join(timeout=5)
        self.assertEqual(answer, [""])
        self.assertEqual(self.records("interrupt")[0]["params"]["threadId"], "thread-1")

    def test_claude_starts_only_on_a_verified_subscription(self):
        self.script.write_text(json.dumps({"rules": [], "auth": {"loggedIn": False}}))
        backend = self.backend(provider="claude")
        with self.assertRaisesRegex(MessengerError, "couldn't confirm Claude is using your Claude subscription"):
            backend.start()
        self.assertEqual([r["argv"] for r in self.records("launch")], [["auth", "status", "--json"]])

    def test_claude_resumes_its_session_after_an_interrupt_and_per_partition(self):
        self.script.write_text(json.dumps({"rules": [{"when": "slow", "reply": "late", "delay": 2}]}))
        backend = self.backend(provider="claude")
        slow = "Current event: user_turn\nCurrent event content:\nslow\nReturn only "
        failures: list = []

        def ask_slowly() -> None:
            try:
                backend.ask(slow, timeout=10)
            except MessengerError as exc:
                failures.append(str(exc))

        worker = threading.Thread(target=ask_slowly)
        worker.start()
        self.wait_for_prompt()
        backend.interrupt()
        worker.join(timeout=5)
        self.assertEqual(failures, ["Claude messenger was interrupted"])
        self.assertEqual(backend.ask("Current event content:\nhello there\nReturn only ", timeout=10),
                         "hello there")
        first_session = self.claude_launches(2)[1][self.claude_launches(2)[1].index("--resume") + 1]
        backend.rebind("other-session")
        self.claude_launches(3)
        backend.rebind("")
        launches = self.claude_launches(4)
        self.assertNotIn("--resume", launches[0])
        self.assertNotIn("--resume", launches[2])  # a new partition starts its own session
        self.assertEqual(launches[3][launches[3].index("--resume") + 1], first_session)


if __name__ == "__main__":
    unittest.main()
