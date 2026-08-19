from __future__ import annotations

import json
import os
import sys
import time
import unittest
from types import SimpleNamespace


ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))
sys.modules.setdefault(
    "numpy",
    SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

from messenger import MessengerRuntime  # noqa: E402
from orchestrator import ContinuityLifecycleAdapter  # noqa: E402
from voice_bridge import _post_continuity_event  # noqa: E402


FORBIDDEN_FIELDS = (
    "transcript",
    "prompt",
    "repository",
    "credential",
    "screenshot",
    "raw_error",
    "raw-error",
    "provider_output",
)


class _FailingMessengerBackend:
    config = SimpleNamespace(provider="claude")

    def start(self):
        return None

    def ask(self, _prompt, timeout=60.0):
        raise RuntimeError("raw-error-secret provider output")

    def interrupt(self):
        return None

    def shutdown(self):
        return None


class ContinuityIntegrationTests(unittest.TestCase):
    def _bridge_payload(self, provider: str, signal: str, observed_at: float) -> dict:
        posted = []
        _post_continuity_event(
            "provider",
            signal,
            {
                "session_id": "native-session-secret",
                "relay_command_id": "native-command-secret",
                "provider": provider,
                "recovery_generation": 4,
                "transcript": "private transcript",
                "prompt": "private prompt",
                "repository": "/private/repository",
                "credential": "secret-token",
                "screenshot": "private-image",
                "raw_error": "raw-error-secret",
                "provider_output": "private provider output",
            },
            observed_at=observed_at,
            request_json=lambda path, payload: posted.append((path, payload)) or {},
        )
        self.assertEqual(posted[0][0], "/v1/continuity/observation")
        self.assertTrue(set(posted[0][1]).isdisjoint(FORBIDDEN_FIELDS))
        return posted[0][1]

    def test_real_bridge_provider_adapter_emits_same_safe_contract_for_codex_and_claude(self):
        emitted = []
        adapter = ContinuityLifecycleAdapter(emit=emitted.append)

        for provider, signal in (("codex", "app_server_timeout"), ("claude", "timeout")):
            for observed_at in (100, 130, 131):
                adapter.observe(self._bridge_payload(provider, signal, observed_at))

        self.assertEqual(len(emitted), 2)
        self.assertEqual({item["provider"] for item in emitted}, {"codex", "claude"})
        self.assertEqual({item["component"] for item in emitted}, {"foreground_provider"})
        serialized = json.dumps(emitted, sort_keys=True)
        for forbidden in (*FORBIDDEN_FIELDS, "native-session-secret", "native-command-secret", "secret-token"):
            self.assertNotIn(forbidden, serialized)

    def test_real_relay_lifecycle_adapter_handles_bridge_messenger_daemon_and_command_events(self):
        emitted = []
        adapter = ContinuityLifecycleAdapter(emit=emitted.append)
        base = {
            "session_id": "relay-session",
            "relay_command_id": "relay-command",
            "provider": "claude",
            "recovery_generation": 2,
        }

        self.assertEqual(adapter.observe({**base, "source": "daemon", "event": "heartbeat", "observed_at": 1}).state, "healthy")
        self.assertEqual(adapter.observe({**base, "source": "command", "event": "accepted", "observed_at": 2}).state, "healthy")
        self.assertEqual(adapter.observe({**base, "source": "bridge", "event": "delivery_failed", "observed_at": 3}).state, "transient")
        self.assertEqual(adapter.observe({**base, "source": "messenger", "event": "failed", "observed_at": 4}).state, "stalled")
        self.assertEqual(adapter.observe({**base, "source": "command", "event": "failed", "observed_at": 5}).state, "stalled")
        self.assertEqual({item["component"] for item in emitted}, {"messenger", "command"})

    def test_messenger_runtime_reports_failure_without_forwarding_raw_error(self):
        observed = []
        runtime = MessengerRuntime(
            _FailingMessengerBackend(),
            speak=lambda *_args, **_kwargs: None,
            is_current=lambda *_args: True,
            continuity_observer=observed.append,
        )
        runtime.start()
        runtime.submit_user("private user transcript", {
            "relay_command_seq": 1,
            "relay_command_id": "command-secret",
        })
        deadline = time.time() + 2
        while not any(event.get("event") == "failed" for event in observed) and time.time() < deadline:
            time.sleep(0.01)
        runtime.shutdown()

        failures = [event for event in observed if event.get("event") == "failed"]
        self.assertEqual(len(failures), 1)
        self.assertEqual(failures[0]["provider"], "claude")
        serialized = json.dumps(failures)
        self.assertNotIn("raw-error-secret", serialized)
        self.assertNotIn("private user transcript", serialized)


if __name__ == "__main__":
    unittest.main()
