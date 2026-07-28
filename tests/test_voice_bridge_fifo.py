from __future__ import annotations

import json
import os
import queue
import stat
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

sys.modules.setdefault(
    "numpy",
    types.SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

import voice_bridge  # noqa: E402
from voice_bridge import ensure_fifo, open_fifo  # noqa: E402


class FakeTTSWorker:
    def __init__(self):
        self.input_queue: queue.Queue = queue.Queue()

    def skip(self):
        pass


class VoiceBridgeFIFOTests(unittest.TestCase):
    def temp_path(self) -> str:
        temp_dir = tempfile.mkdtemp()
        self.addCleanup(lambda: os.path.isdir(temp_dir) and os.rmdir(temp_dir))
        path = os.path.join(temp_dir, "voice_in.fifo")
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        return path

    def assert_fifo(self, path: str) -> None:
        self.assertTrue(stat.S_ISFIFO(os.stat(path).st_mode))

    def test_ensure_fifo_replaces_regular_file(self):
        path = self.temp_path()
        with open(path, "w") as f:
            f.write("stale data")

        self.assertTrue(ensure_fifo(path))

        self.assert_fifo(path)

    def test_open_fifo_repairs_regular_file_before_opening(self):
        path = self.temp_path()
        with open(path, "w") as f:
            f.write("stale data")

        fd = open_fifo(path)
        self.addCleanup(lambda: fd is not None and os.close(fd))

        self.assertIsNotNone(fd)
        self.assert_fifo(path)

    def test_raw_reserved_reply_written_to_fifo_never_enters_command_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            paths = {
                "VOICE_FIFO": os.path.join(temp_dir, "voice_in.fifo"),
                "TTS_IN_FIFO": os.path.join(temp_dir, "tts_in.fifo"),
                "VOICE_CMD_FILE": os.path.join(temp_dir, "voice_cmd_ready"),
                "VOICE_CMD_META_FILE": os.path.join(temp_dir, "voice_cmd_ready.meta"),
                "VOICE_COMMAND_STATE_FILE": os.path.join(temp_dir, "voice_command_state.json"),
                "VOICE_COMMAND_CLAIM_FILE": os.path.join(temp_dir, "voice_cmd_claimed.json"),
                "VOICE_MANUAL_CLAIM_ACK_FILE": os.path.join(temp_dir, "voice_cmd_manual_ack.json"),
                "VOICE_COMMAND_AUTHORIZATION_FILE": os.path.join(
                    temp_dir, "voice_command_authorizations.json"
                ),
                "VOICE_PROVIDER_TURNS_FILE": os.path.join(temp_dir, "voice_provider_turns.json"),
            }
            current = {
                "relay_command_seq": 41,
                "relay_command_id": "cmd-41",
                "source_text": "dispatch RR-247",
            }
            Path(paths["VOICE_COMMAND_STATE_FILE"]).write_text(json.dumps(current))
            Path(paths["VOICE_COMMAND_CLAIM_FILE"]).write_text(json.dumps(current))
            raw_reply = json.dumps({
                "type": "__ORCHESTRATOR_REPLY__",
                "relay_command_seq": 41,
                "relay_command_id": "cmd-41",
                "text": "Dispatched RR-247; create and update ticket next.",
            }) + "\n"
            shutdown = threading.Event()
            quarantined = threading.Event()
            worker = FakeTTSWorker()

            patches = [
                mock.patch.object(voice_bridge, name, value)
                for name, value in paths.items()
            ]
            for patcher in patches:
                patcher.start()
                self.addCleanup(patcher.stop)
            with (
                mock.patch.object(voice_bridge.os, "unlink"),
                mock.patch.object(
                    voice_bridge,
                    "_log_quarantined_relay_control",
                    side_effect=lambda **_kwargs: quarantined.set(),
                ),
                mock.patch.object(voice_bridge, "_begin_relay_command") as begin_command,
                mock.patch.object(voice_bridge, "resolve_command_action") as classify,
                mock.patch.object(voice_bridge, "_publish_command") as publish,
            ):
                bridge = threading.Thread(
                    target=voice_bridge._run_relay,
                    args=(worker, shutdown),
                    kwargs={"suppress_startup_greeting": True},
                    daemon=True,
                )
                bridge.start()
                deadline = time.time() + 2
                writer = None
                while writer is None and time.time() < deadline:
                    try:
                        writer = os.open(
                            paths["VOICE_FIFO"],
                            os.O_WRONLY | os.O_NONBLOCK,
                        )
                    except (FileNotFoundError, OSError):
                        time.sleep(0.01)
                self.assertIsNotNone(writer)
                with os.fdopen(writer, "w") as fifo:
                    fifo.write(raw_reply)
                self.assertTrue(quarantined.wait(timeout=2))

                self.assertEqual(
                    json.loads(Path(paths["VOICE_COMMAND_STATE_FILE"]).read_text()),
                    current,
                )
                self.assertEqual(
                    json.loads(Path(paths["VOICE_COMMAND_CLAIM_FILE"]).read_text()),
                    current,
                )
                self.assertFalse(Path(paths["VOICE_CMD_FILE"]).exists())
                self.assertFalse(Path(paths["VOICE_CMD_META_FILE"]).exists())
                begin_command.assert_not_called()
                classify.assert_not_called()
                publish.assert_not_called()

                shutdown.set()
                bridge.join(timeout=2)
                self.assertFalse(bridge.is_alive())


if __name__ == "__main__":
    unittest.main()
