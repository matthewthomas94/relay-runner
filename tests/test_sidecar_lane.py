from __future__ import annotations

import os
import sys
import threading
import unittest

ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

from messenger import MessengerConfig  # noqa: E402
from sidecar_lane import (  # noqa: E402
    ClaudeSidecarBackend,
    CodexSidecarBackend,
    ProviderSidecarExecutor,
    SidecarLane,
)


def command(seq: int) -> dict:
    return {
        "relay_command_seq": seq,
        "relay_command_id": f"cmd-{seq}",
        "work_disposition": {
            "route": "run_sidecar",
            "public_reason": "Independent bounded public research.",
        },
    }


class SidecarLaneTests(unittest.TestCase):
    def test_lane_runs_concurrently_and_bounds_pending_work(self):
        started = threading.Event()
        release = threading.Event()
        finished = threading.Event()
        lifecycle = []
        finals = []

        def execute(prompt: str, timeout: float) -> str:
            self.assertEqual(timeout, 5.0)
            started.set()
            self.assertTrue(release.wait(2))
            return f"result for {prompt}"

        def on_final(text: str, metadata: dict) -> None:
            finals.append((text, metadata["relay_command_id"]))
            if len(finals) == 2:
                finished.set()

        lane = SidecarLane(
            execute,
            on_lifecycle=lifecycle.append,
            on_final=on_final,
            timeout=5,
            max_pending=1,
        )
        try:
            self.assertTrue(lane.submit("first", command(1)))
            self.assertTrue(started.wait(1))
            self.assertTrue(lane.submit("second", command(2)))
            self.assertFalse(lane.submit("third", command(3)))
            release.set()
            self.assertTrue(finished.wait(2))
        finally:
            lane.shutdown()

        self.assertEqual(
            [(event.phase, event.command["relay_command_id"]) for event in lifecycle],
            [
                ("started", "cmd-1"),
                ("completed", "cmd-1"),
                ("started", "cmd-2"),
                ("completed", "cmd-2"),
            ],
        )
        self.assertEqual(
            finals,
            [
                ("result for first", "cmd-1"),
                ("result for second", "cmd-2"),
            ],
        )

    def test_lane_reports_provider_failure_as_lifecycle_and_final(self):
        finished = threading.Event()
        lifecycle = []
        finals = []

        def execute(_prompt: str, _timeout: float) -> str:
            raise RuntimeError("private provider detail")

        def on_final(text: str, metadata: dict) -> None:
            finals.append((text, metadata))
            finished.set()

        lane = SidecarLane(
            execute,
            on_lifecycle=lifecycle.append,
            on_final=on_final,
        )
        try:
            self.assertTrue(lane.submit("research", command(1)))
            self.assertTrue(finished.wait(2))
        finally:
            lane.shutdown()

        self.assertEqual([event.phase for event in lifecycle], ["started", "failed"])
        self.assertNotIn("private provider detail", finals[0][0])

    def test_codex_and_claude_backends_enforce_the_same_read_only_boundary(self):
        codex_config = MessengerConfig(
            enabled=True,
            provider="codex",
            command="/opt/codex",
            model="gpt-test",
            effort="high",
            cwd="/tmp",
        )
        codex = CodexSidecarBackend(codex_config)
        self.assertEqual(codex.actor_role, "sidecar")
        codex_command = codex.spawn_command()
        codex_params = codex.thread_start_params()
        self.assertIn("tools.web_search=true", codex_command)
        self.assertIn("features.shell_tool=false", codex_command)
        self.assertIn("features.unified_exec=false", codex_command)
        self.assertEqual(codex_params["sandbox"], "read-only")
        self.assertEqual(codex_params["runtimeWorkspaceRoots"], [])

        claude_config = MessengerConfig(
            enabled=True,
            provider="claude",
            command="/opt/claude",
            model="sonnet",
            effort="high",
            cwd="/tmp",
        )
        claude = ClaudeSidecarBackend(claude_config)
        self.assertEqual(claude.actor_role, "sidecar")
        claude_command = claude.spawn_command()
        self.assertIn("WebSearch,WebFetch", claude_command)
        self.assertIn("--safe-mode", claude_command)
        self.assertIn("--no-chrome", claude_command)
        self.assertIn("dontAsk", claude_command)
        self.assertNotIn("Bash", claude_command)

    def test_provider_executor_shuts_down_its_one_shot_backend(self):
        calls = []

        class Backend:
            def ask(self, prompt: str, timeout: float) -> str:
                calls.append(("ask", prompt, timeout))
                return "verified result"

            def shutdown(self) -> None:
                calls.append(("shutdown",))

        config = MessengerConfig(True, "codex", "/opt/codex", "gpt-test", "high", "/tmp")
        executor = ProviderSidecarExecutor(config, backend_factory=lambda _config: Backend())

        self.assertEqual(executor("compare the APIs", 12), "verified result")
        self.assertIn("compare the APIs", calls[0][1])
        self.assertEqual(calls[0][2], 12)
        self.assertEqual(calls[-1], ("shutdown",))


if __name__ == "__main__":
    unittest.main()
