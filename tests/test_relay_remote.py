"""RR-423: Relay Remote device sessions feed the bridge's ordered command path."""

from __future__ import annotations

import json
import os
import socket
import stat
import sys
import tempfile
import threading
import time
import types
import unittest
import uuid
from pathlib import Path
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)
sys.modules.setdefault("numpy", types.SimpleNamespace(asarray=lambda s: s, int16=object()))

import relay_remote  # noqa: E402
import relay_remote_protocol as proto  # noqa: E402
import voice_bridge  # noqa: E402


def wait_until(predicate, timeout: float = 3.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return bool(predicate())


class Device:
    """A scripted phone speaking NDJSON frames over the bridge socket."""

    def __init__(self, path: str):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(3)
        self.sock.connect(path)
        self.reader = self.sock.makefile("rb")

    def send(self, frame) -> None:
        self.sock.sendall(proto.encode(frame))

    def send_raw(self, data: bytes) -> None:
        self.sock.sendall(data)

    def recv(self):
        line = self.reader.readline()
        if not line:
            raise EOFError("connection closed")
        return proto.decode(line)

    def hello(self, device_id: str = "phone-1", resume_after_seq=None):
        self.send(proto.Hello(device_id, "iPhone", "0.1", resume_after_seq))
        return self.recv()

    def close(self) -> None:
        self.reader.close()
        self.sock.close()


def utterance(text: str, client_id: str | None = None) -> proto.Utterance:
    return proto.Utterance(client_id or str(uuid.uuid4()), text, "2026-10-22T09:14:03Z")


class ServerTestCase(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir="/tmp", prefix="rr423-")
        self.addCleanup(temp.cleanup)
        self.root = temp.name
        self.path = os.path.join(self.root, "relay_remote.sock")

    def start_server(self, *, attached: bool = True, **kwargs) -> relay_remote.RelayRemoteServer:
        server = relay_remote.RelayRemoteServer(relay_remote.RemoteIngress(), self.path, **kwargs)
        server.ingress.attached = attached
        server.start()
        self.addCleanup(server.close)
        return server

    def device(self) -> Device:
        device = Device(self.path)
        self.addCleanup(device.close)
        return device


class RelayRemoteServerTests(ServerTestCase):
    def test_socket_is_private_to_the_user(self):
        self.start_server()
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)

    def test_other_uid_is_refused_before_any_frame_is_read(self):
        peers = []

        def foreign_uid(conn):
            peers.append(conn)
            return os.getuid() + 1

        server = self.start_server(peer_uid=foreign_uid)
        with mock.patch.object(relay_remote.proto, "decode") as decode:
            device = self.device()
            try:
                device.send(proto.Hello("phone-1", "iPhone", "0.1"))
                device.send(utterance("open the board"))
                self.assertEqual(device.reader.readline(), b"")
            except (BrokenPipeError, ConnectionResetError):
                pass  # The server may close before the device finishes writing.
            self.assertTrue(wait_until(lambda: peers))
        self.assertEqual(len(peers), 1)
        decode.assert_not_called()
        self.assertIsNone(server.session("phone-1"))
        self.assertEqual(server.ingress.drain(), [])

    def test_hello_is_welcomed_and_ping_answered(self):
        self.start_server()
        device = self.device()
        welcome = device.hello()
        self.assertEqual(
            welcome,
            proto.Welcome(session_state="running", server_seq=0, dropped=False),
        )
        device.send(proto.Ping(1761124443))
        self.assertEqual(device.recv(), proto.Pong(1761124443))

    def test_first_frame_must_be_hello(self):
        server = self.start_server()
        device = self.device()
        device.send(utterance("open the board"))
        self.assertEqual(device.recv().code, "hello_required")
        self.assertEqual(device.reader.readline(), b"")
        self.assertEqual(server.ingress.drain(), [])

    def test_rejected_input_gets_error_frames(self):
        server = self.start_server()
        device = self.device()
        device.hello()
        device.send_raw(b'{"type":"teleport"}\n')
        self.assertEqual(device.recv().code, "unknown_type")
        device.send_raw(b"x" * (proto.MAX_LINE_BYTES + 10) + b"\n")
        self.assertEqual(device.recv().code, "line_too_long")
        device.send(utterance("__CANCEL__"))
        self.assertEqual(device.recv().code, "invalid_utterance")
        device.send(proto.Ping(7))
        self.assertEqual(device.recv(), proto.Pong(7))
        self.assertEqual(server.ingress.drain(), [])

    def test_no_running_session_rejects_input(self):
        server = self.start_server(attached=False)
        device = self.device()
        self.assertEqual(device.hello().session_state, "idle")
        device.send(utterance("open the board"))
        error = device.recv()
        self.assertEqual(error.code, "no_session")
        device.send(proto.Control(str(uuid.uuid4()), "stop"))
        self.assertEqual(device.recv().code, "no_session")
        self.assertEqual(server.ingress.drain(), [])

    def test_second_connection_replaces_the_first(self):
        server = self.start_server()
        first = self.device()
        first.hello()
        second = self.device()
        second.hello()
        self.assertEqual(first.reader.readline(), b"")
        self.assertTrue(wait_until(lambda: server.session("phone-1").conn is not None))
        second.send(proto.Ping(3))
        self.assertEqual(second.recv(), proto.Pong(3))

    def test_retried_utterance_is_accepted_once_and_queued_once(self):
        server = self.start_server()
        client_id = str(uuid.uuid4())
        device = self.device()
        device.hello()
        device.send(utterance("dispatch RR-120", client_id))
        self.assertTrue(wait_until(lambda: server.ingress._items))
        [item] = server.ingress.drain()
        item.on_accepted({"relay_command_seq": 812, "relay_command_id": "4711-1-812"})
        accepted = device.recv()
        self.assertEqual(accepted, proto.Accepted(client_id, 812, "4711-1-812"))

        # The phone lost the connection before it saw the receipt and retries.
        device.close()
        retry = self.device()
        retry.hello(resume_after_seq=0)
        retry.send(utterance("dispatch RR-120", client_id.upper()))
        self.assertEqual(retry.recv(), accepted)
        retry.send(proto.Ping(9))
        self.assertEqual(retry.recv(), proto.Pong(9))
        self.assertEqual(server.ingress.drain(), [])

    def test_hello_resume_replays_missed_frames_in_order(self):
        server = self.start_server()
        device = self.device()
        device.hello()
        session = server.session("phone-1")
        for text in ("one", "two", "three", "four"):
            session.emit(lambda seq, text=text: proto.Status(seq, text))
        self.assertEqual([device.recv().seq for _ in range(4)], [1, 2, 3, 4])
        device.send(proto.Ack(1, True))
        device.close()
        session.emit(lambda seq: proto.Status(seq, "while away"))

        again = self.device()
        welcome = again.hello(resume_after_seq=2)
        self.assertEqual(
            welcome,
            proto.Welcome(session_state="running", server_seq=5, dropped=False, resumed_from=2),
        )
        self.assertEqual(
            [again.recv() for _ in range(3)],
            [proto.Status(3, "three"), proto.Status(4, "four"), proto.Status(5, "while away")],
        )

    def test_controls_map_to_existing_fifo_tokens(self):
        server = self.start_server()
        device = self.device()
        device.hello()
        for action in ("stop", "interrupt", "cancel", "play", "replay"):
            device.send(proto.Control(str(uuid.uuid4()), action))
        self.assertTrue(wait_until(lambda: len(server.ingress._items) == 5))
        items = server.ingress.drain()
        self.assertEqual(
            [item.text for item in items],
            ["__TTS_STOP__", "__INTERRUPT__", "__CANCEL__", "__PLAY__", "__REPLAY__"],
        )
        self.assertTrue(all(item.is_control for item in items))


class BridgeRemoteIngressTests(ServerTestCase):
    """The real relay loop orders FIFO and remote input on one command counter."""

    def setUp(self):
        super().setUp()
        self.paths = {
            "VOICE_FIFO": os.path.join(self.root, "voice_in.fifo"),
            "TTS_IN_FIFO": os.path.join(self.root, "tts_in.fifo"),
            "VOICE_CMD_FILE": os.path.join(self.root, "voice_cmd_ready"),
            "VOICE_CMD_META_FILE": os.path.join(self.root, "voice_cmd_ready.meta"),
            "VOICE_COMMAND_STATE_FILE": os.path.join(self.root, "voice_command_state.json"),
            "VOICE_COMMAND_CLAIM_FILE": os.path.join(self.root, "voice_cmd_claimed.json"),
            "VOICE_MANUAL_CLAIM_ACK_FILE": os.path.join(self.root, "voice_cmd_manual_ack.json"),
            "VOICE_COMMAND_AUTHORIZATION_FILE": os.path.join(self.root, "authorizations.json"),
            "VOICE_PROVIDER_TURNS_FILE": os.path.join(self.root, "voice_provider_turns.json"),
            "_MIRRORED_COMMAND_STATE_FILE": None,
        }
        real_begin = voice_bridge._begin_relay_command
        state_path = self.paths["VOICE_COMMAND_STATE_FILE"]
        self.published: list[dict] = []
        real_publish = voice_bridge._publish_command

        def publish(text, metadata, **kwargs):
            self.published.append(dict(metadata))
            return real_publish(text, metadata, **kwargs)

        self.control_texts: list[str] = []
        real_control = voice_bridge._handle_relay_control_message

        def control(text, *args, **kwargs):
            if text.startswith("__") and text.endswith("__"):
                self.control_texts.append(text)
                return True
            return real_control(text, *args, **kwargs)

        patchers = [
            mock.patch.multiple(voice_bridge, **self.paths),
            mock.patch.dict(os.environ, {"RELAY_SESSION_SPOOL_DIR": self.root}),
            mock.patch.object(
                voice_bridge,
                "_begin_relay_command",
                side_effect=lambda text, *_a, **kw: real_begin(
                    text,
                    state_path=state_path,
                    event_log_path=None,
                    input_source=kw.get("input_source"),
                    device_id=kw.get("device_id"),
                ),
            ),
            mock.patch.object(voice_bridge, "_publish_command", side_effect=publish),
            mock.patch.object(voice_bridge, "_handle_relay_control_message", side_effect=control),
            mock.patch.object(voice_bridge, "_post_continuity_event"),
            mock.patch.object(voice_bridge, "_record_private_command_capture"),
            mock.patch.object(voice_bridge, "_tts_fifo_reader"),
            mock.patch.object(voice_bridge, "_active_work", return_value=[]),
            mock.patch.object(voice_bridge, "_any_provider_turn_active", return_value=False),
            mock.patch.object(voice_bridge, "_queue_voice_acknowledgement"),
            mock.patch.object(voice_bridge, "record_command_authorization"),
            mock.patch.object(voice_bridge, "_should_fanout_raw_instruction_to_orchestrator", return_value=False),
            mock.patch.object(voice_bridge, "_start_pm_update_mode"),
        ]
        for patcher in patchers:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.addCleanup(voice_bridge._clear_voice_targets)

        self.server = self.start_server(attached=False)
        self.shutdown = threading.Event()
        worker = mock.MagicMock()
        self.bridge = threading.Thread(
            target=voice_bridge._run_relay,
            args=(worker, self.shutdown),
            kwargs={
                "suppress_startup_greeting": True,
                "messenger_expected": False,
                "remote_ingress": self.server.ingress,
            },
            daemon=True,
        )
        self.bridge.start()
        self.addCleanup(self.stop_bridge)
        self.assertTrue(wait_until(lambda: self.server.ingress.attached))
        self.fifo = os.fdopen(os.open(self.paths["VOICE_FIFO"], os.O_WRONLY | os.O_NONBLOCK), "w")
        self.addCleanup(self.fifo.close)

    def stop_bridge(self):
        self.shutdown.set()
        self.bridge.join(timeout=3)
        self.assertFalse(self.bridge.is_alive())
        self.assertFalse(self.server.ingress.attached)

    def mic(self, text: str) -> None:
        self.fifo.write(text + "\n")
        self.fifo.flush()

    def state(self) -> dict:
        return json.loads(Path(self.paths["VOICE_COMMAND_STATE_FILE"]).read_text())

    def meta(self) -> dict:
        return json.loads(Path(self.paths["VOICE_CMD_META_FILE"]).read_text())

    def wait_for_seq(self, seq: int) -> None:
        self.assertTrue(wait_until(
            lambda: any(m["relay_command_seq"] == seq for m in self.published)
            and os.path.exists(self.paths["VOICE_CMD_META_FILE"])
            and self.meta()["relay_command_seq"] == seq
        ))

    def test_fifo_and_remote_commands_share_one_ordered_sequence(self):
        device = self.device()
        device.hello(device_id="phone-1")

        self.mic("first from the mac")
        self.wait_for_seq(1)
        self.assertNotIn("input_source", self.meta())
        self.assertNotIn("device_id", self.state())

        device.send(utterance("second from the phone"))
        accepted = device.recv()
        self.assertEqual(accepted.relay_command_seq, 2)
        self.wait_for_seq(2)
        for record in (self.meta(), self.state()):
            self.assertEqual(record["relay_command_seq"], 2)
            self.assertEqual(record["relay_command_id"], accepted.relay_command_id)
            self.assertEqual(record["input_source"], "remote")
            self.assertEqual(record["device_id"], "phone-1")

        self.mic("third from the mac")
        self.wait_for_seq(3)
        device.send(utterance("fourth from the phone"))
        self.assertEqual(device.recv().relay_command_seq, 4)
        self.wait_for_seq(4)
        self.mic("fifth from the mac")
        self.wait_for_seq(5)
        self.assertNotIn("input_source", self.meta())
        self.assertNotIn("input_source", self.state())

        firsts = {}
        for metadata in self.published:
            firsts.setdefault(metadata["relay_command_seq"], metadata)
        self.assertEqual(
            [(seq, firsts[seq]["source_text"], firsts[seq].get("input_source")) for seq in sorted(firsts)],
            [
                (1, "first from the mac", None),
                (2, "second from the phone", "remote"),
                (3, "third from the mac", None),
                (4, "fourth from the phone", "remote"),
                (5, "fifth from the mac", None),
            ],
        )

    def test_remote_controls_reach_the_fifo_control_path(self):
        device = self.device()
        device.hello()
        tokens = ["__TTS_STOP__", "__INTERRUPT__", "__CANCEL__", "__PLAY__", "__REPLAY__"]
        for action in ("stop", "interrupt", "cancel", "play", "replay"):
            device.send(proto.Control(str(uuid.uuid4()), action))
        self.assertTrue(wait_until(lambda: len(self.control_texts) == 5))
        self.assertEqual(self.control_texts, tokens)
        self.mic("__TTS_STOP__")
        self.assertTrue(wait_until(lambda: len(self.control_texts) == 6))
        self.assertEqual(self.published, [])


if __name__ == "__main__":
    unittest.main()
