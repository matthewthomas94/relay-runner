"""RR-398: one shared bridge re-targets the focused session with ``__FOCUS__``."""

from __future__ import annotations

import json
import os
import queue
import socket
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)
sys.modules.setdefault("numpy", types.SimpleNamespace(asarray=lambda s: s, int16=object()))

import voice_bridge  # noqa: E402
from intent_inbox import IntentInbox  # noqa: E402


def wait_until(predicate, timeout: float = 2.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return bool(predicate())


class FocusTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/tmp", prefix="rr398-")
        self.addCleanup(self.temp.cleanup)
        self.root = self.temp.name
        self.sessions = os.path.join(self.root, "sessions")
        startup = os.path.join(self.sessions, "startup")
        os.makedirs(startup)
        patches = {
            "RELAY_SESSIONS_ROOT": self.sessions,
            "BRIDGE_CWD_FILE": os.path.join(self.root, "bridge.cwd"),
            "BRIDGE_PROVIDER_FILE": os.path.join(self.root, "bridge.provider"),
            "BRIDGE_SPOOL_FILE": os.path.join(self.root, "bridge.spool"),
            "VOICE_CMD_FILE": os.path.join(startup, "voice_cmd_ready"),
            "VOICE_CMD_META_FILE": os.path.join(startup, "voice_cmd_ready.meta"),
            "VOICE_COMMAND_CLAIM_FILE": os.path.join(startup, "voice_cmd_claimed.json"),
            "VOICE_MANUAL_CLAIM_ACK_FILE": os.path.join(startup, "voice_cmd_manual_ack.json"),
            "VOICE_COMMAND_STATE_FILE": os.path.join(startup, "voice_command_state.json"),
            "_MIRRORED_COMMAND_STATE_FILE": None,
            "_PROVIDER_SESSION_OWNERSHIP": None,
        }
        patcher = mock.patch.multiple(voice_bridge, **patches)
        patcher.start()
        self.addCleanup(patcher.stop)
        env = mock.patch.dict(os.environ, {
            "RELAY_SESSION_SPOOL_DIR": startup,
            "RELAY_SESSION_KEY": "startup",
            "RELAY_RUNNER_PROVIDER": "claude",
        })
        env.start()
        self.addCleanup(env.stop)
        voice_bridge._install_startup_voice_target()
        self.addCleanup(voice_bridge._clear_voice_targets)

    def focus_payload(self, key: str, provider: str, *, live=None, focus=True) -> dict:
        payload = {
            "session_key": key,
            "provider": provider,
            "provider_session_id": f"{provider}-{key}-native",
            "cwd": os.path.join(self.root, f"repo-{key}"),
            "spool_dir": os.path.join(self.sessions, key),
            "app_session_id": f"app-{key}",
            "recovery_generation": "1",
            "project_name": f"Project {key}",
            "focus": focus,
        }
        if live is not None:
            payload["live_session_keys"] = live
        return payload

    def focus(self, key: str, provider: str = "codex", **kwargs):
        return voice_bridge._apply_voice_focus(self.focus_payload(key, provider, **kwargs))


class VoiceFocusTargetTests(FocusTestCase):
    def test_focus_retargets_the_live_bridge_with_each_providers_native_binding(self):
        a = self.focus("A", "codex", live=["startup", "A"])
        b = self.focus("B", "claude", live=["startup", "A", "B"])

        self.assertEqual(voice_bridge._current_voice_target(), b)
        self.assertEqual(voice_bridge._voice_target_for("A"), a)
        self.assertEqual(a.provider_session_id, "codex-A-native")
        self.assertEqual(b.provider_session_id, "claude-B-native")
        self.assertEqual(voice_bridge._authoritative_provider_session_id(), "claude-B-native")
        with open(voice_bridge.BRIDGE_SPOOL_FILE) as f:
            self.assertEqual(f.read().strip(), b.spool_dir)
        with open(voice_bridge.BRIDGE_PROVIDER_FILE) as f:
            self.assertEqual(f.read().strip(), "claude")

    def test_focus_rejects_spools_outside_the_session_root(self):
        payload = self.focus_payload("A", "codex")
        payload["spool_dir"] = os.path.join(self.root, "elsewhere", "A")
        self.assertIsNone(voice_bridge._apply_voice_focus(payload))
        payload = self.focus_payload("../A", "codex")
        self.assertIsNone(voice_bridge._apply_voice_focus(payload))
        self.assertEqual(voice_bridge._current_voice_target().session_key, "startup")

    def test_a_command_reaches_only_the_focused_sessions_spool(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                inbox = IntentInbox(os.path.join(self.root, f"{provider}.sqlite3"))
                self.addCleanup(inbox.close)
                a = self.focus(f"A-{provider}", provider)
                b = self.focus(f"B-{provider}", provider)
                metadata = {
                    "relay_command_seq": 7,
                    "relay_command_id": f"cmd-{provider}",
                    "intent_id": f"intent-{provider}",
                    "voice_target_session_key": b.session_key,
                }
                voice_bridge._publish_command(
                    "ship it",
                    metadata,
                    command_path=b.command_path,
                    meta_path=b.meta_path,
                    state_path=voice_bridge.VOICE_COMMAND_STATE_FILE,
                    inbox=inbox,
                )
                with open(b.command_path) as f:
                    self.assertEqual(f.read(), "ship it")
                self.assertFalse(os.path.exists(a.command_path))
                self.assertFalse(os.path.exists(voice_bridge.VOICE_CMD_FILE))
                # Every live session's hooks see the shared command ledger.
                with open(b.state_path) as f:
                    self.assertEqual(json.load(f)["relay_command_id"], f"cmd-{provider}")
                os.unlink(b.command_path)
                os.unlink(b.meta_path)

    def test_ending_the_focused_session_hands_its_queued_command_to_the_next_session(self):
        a = self.focus("A", "codex", live=["startup", "A"])
        b = self.focus("B", "claude", live=["startup", "A", "B"])
        os.makedirs(b.spool_dir, exist_ok=True)
        with open(b.command_path, "w") as f:
            f.write("queued for B")
        with open(b.meta_path, "w") as f:
            json.dump({"intent_id": "queued"}, f)

        self.focus("A", "codex", live=["startup", "A"])

        self.assertIsNone(voice_bridge._voice_target_for("B"))
        self.assertEqual(voice_bridge._current_voice_target().session_key, "A")
        with open(a.command_path) as f:
            self.assertEqual(f.read(), "queued for B")
        self.assertFalse(os.path.exists(b.command_path))

    def test_each_non_startup_session_registers_and_stops_its_own_orchestrator(self):
        started, stopped = [], []

        def start(target):
            started.append(target.session_key)
            return {"session_id": len(started), "target": target.session_key}

        payload = self.focus_payload("A", "codex", live=["startup", "A"])
        voice_bridge._apply_voice_focus(payload, start_orchestrator=start, stop_orchestrator=stopped.append)
        self.assertTrue(wait_until(lambda: voice_bridge._voice_target_orchestrator(
            voice_bridge._voice_target_for("A"), None) is not None))
        voice_bridge._apply_voice_focus(payload, start_orchestrator=start, stop_orchestrator=stopped.append)
        self.assertEqual(started, ["A"])
        bridge_session = {"session_id": 99}
        startup = voice_bridge._voice_target_for("startup")
        self.assertIs(voice_bridge._voice_target_orchestrator(startup, bridge_session), bridge_session)

        voice_bridge._apply_voice_focus(
            self.focus_payload("startup-2", "claude", live=["startup", "startup-2"]),
            stop_orchestrator=stopped.append,
        )
        self.assertEqual(stopped, [{"session_id": 1, "target": "A"}])


class VoiceFocusControlSocketTests(FocusTestCase):
    def test_focus_datagram_retargets_without_stopping_the_bridge(self):
        sock_path = os.path.join(self.root, "c.sock")
        shutdown = threading.Event()
        worker = types.SimpleNamespace(reload_config=lambda: None)
        context = {}
        with mock.patch.object(voice_bridge, "BRIDGE_CONTROL_SOCK", sock_path):
            thread = threading.Thread(
                target=voice_bridge._start_control_socket,
                args=(worker, shutdown, context),
                daemon=True,
            )
            thread.start()
            self.addCleanup(thread.join, 2)
            self.addCleanup(shutdown.set)
            self.assertTrue(wait_until(lambda: os.path.exists(sock_path)))
            client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            self.addCleanup(client.close)
            message = voice_bridge.VOICE_FOCUS_PREFIX + json.dumps(self.focus_payload("B", "codex"))
            client.sendto(message.encode(), sock_path)
            self.assertTrue(wait_until(
                lambda: getattr(voice_bridge._current_voice_target(), "session_key", "") == "B"
            ))
        self.assertFalse(shutdown.is_set())
        self.assertTrue(thread.is_alive())
        self.assertEqual(
            context["provider_session_ownership"].provider_session_id(),
            "codex-B-native",
        )


class RecordingPinTests(FocusTestCase):
    def test_recording_started_on_a_is_delivered_to_a_after_focus_moves_to_b(self):
        a = self.focus("A", "codex")
        shutdown = threading.Event()
        reads = iter([
            b"__VOICE_TARGET__:A\n",
            None,  # focus moves to B while the recording is still being transcribed
            b"add a test\n",
        ])

        def read(_fd, _size):
            chunk = next(reads)
            if chunk is None:
                self.focus("B", "claude")
                return b"\n"
            if chunk == b"add a test\n":
                shutdown.set()
            return chunk

        resolved = {
            "item": types.SimpleNamespace(
                lifecycle_state="recognized", to_dict=lambda: {}, source_text="add a test",
                intent_id="i-1", within_turn_order=1,
            ),
            "action": types.SimpleNamespace(outcome="non_work"),
            "disposition": types.SimpleNamespace(
                route=voice_bridge.IntentRoute.CONTINUE_CURRENT,
                to_dict=lambda: {}, intent_id="i-1",
            ),
            "metadata": {"relay_command_seq": 1, "relay_command_id": "c-1"},
            "prompt": "add a test",
        }
        with (
            mock.patch.object(voice_bridge.os, "close"),
            mock.patch.object(voice_bridge.os, "read", side_effect=read),
            mock.patch.object(voice_bridge, "ensure_fifo", return_value=True),
            mock.patch.object(voice_bridge, "open_fifo", return_value=123),
            mock.patch.object(voice_bridge.select, "select", return_value=([123], [], [])),
            mock.patch.object(voice_bridge, "_tts_fifo_reader"),
            mock.patch.object(voice_bridge, "_begin_relay_command", return_value={
                "relay_command_seq": 1, "relay_command_id": "c-1", "received_at": 1.0,
            }),
            mock.patch.object(voice_bridge, "_active_work", return_value=[]) as active_work,
            mock.patch.object(voice_bridge, "_resolve_voice_work_items", return_value=[resolved]),
            mock.patch.object(voice_bridge, "_queue_voice_acknowledgement"),
            mock.patch.object(voice_bridge, "_queue_messenger_degraded"),
            mock.patch.object(voice_bridge, "record_command_authorization"),
            mock.patch.object(voice_bridge, "_record_command_action_state"),
            mock.patch.object(voice_bridge, "_should_fanout_raw_instruction_to_orchestrator", return_value=False),
            mock.patch.object(voice_bridge, "_start_pm_update_mode"),
            mock.patch.object(voice_bridge, "_publish_command") as publish,
        ):
            worker = types.SimpleNamespace(input_queue=queue.Queue(), skip=lambda: None)
            # Keep the targets registered above; _run_relay installs only when empty.
            voice_bridge._run_relay(worker, shutdown, messenger_expected=False, suppress_startup_greeting=True)

        publish.assert_called_once()
        kwargs = publish.call_args.kwargs
        self.assertEqual(kwargs["command_path"], a.command_path)
        self.assertEqual(kwargs["meta_path"], a.meta_path)
        metadata = publish.call_args.args[1]
        self.assertEqual(metadata["voice_target_session_key"], "A")
        self.assertEqual(metadata["provider"], "codex")
        self.assertEqual(str(active_work.call_args.kwargs["repo_path"]), a.cwd)


if __name__ == "__main__":
    unittest.main()
