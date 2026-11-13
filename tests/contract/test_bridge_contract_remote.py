"""Voice bridge contract: Relay Remote device sessions on `RELAY_REMOTE_SOCK`
(docs/specs/voice-bridge-contract.md, "Relay Remote").

Frames are checked against the shared vectors in
`tests/RelayRemoteProtocolTests/Vectors`, the same files the Swift
`RelayRemoteProtocol` tests read.

RR-491: the `Rust` classes run the same cases against the reference bridge with
`RELAY_REMOTE_RUNTIME=rust`, so the socket is served by `relay-rs remote`. They
need a release build (`cargo build --release` in rust/) and skip without one.
"""

from __future__ import annotations

import json
import os
import socket
import threading
import unittest
import uuid

from bridge_contract_support import (
    BRIDGE_IS_REFERENCE,
    REPO_ROOT,
    WAIT_SECONDS,
    BridgeCase,
    load_vectors,
    wait_until,
)

FRAMES = {vector["name"]: vector for vector in load_vectors("frames")}
INVALID = load_vectors("invalid")
LIMITS = load_vectors("limits")
DEVICE_ID = json.loads(FRAMES["hello"]["line"])["device_id"]


def encoded(frame: dict) -> bytes:
    """The wire form of a frame: compact, sorted-key JSON and a newline."""
    return json.dumps(frame, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"


def vector_line(name: str, **changes) -> str:
    """A vector's line, optionally with some fields replaced."""
    frame = json.loads(FRAMES[name]["line"])
    frame.update(changes)
    return json.dumps(frame, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


class Device:
    """The forced-command helper's side of one connection: lines in, frames out."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(str(path))
        self.raw: list = []
        self.frames: list = []
        self.closed = threading.Event()
        self._lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        try:
            with self.sock.makefile("rb") as reader:
                for line in reader:
                    with self._lock:
                        self.raw.append(line)
                        self.frames.append(json.loads(line))
        except (OSError, ValueError):
            pass
        finally:
            self.closed.set()

    def send(self, line) -> None:
        data = line if isinstance(line, bytes) else line.encode("utf-8")
        self.sock.sendall(data + b"\n")

    def of(self, frame_type: str) -> list:
        with self._lock:
            return [frame for frame in self.frames if frame.get("type") == frame_type]

    def raw_of(self, frame_type: str) -> list:
        with self._lock:
            return [line for line, frame in zip(self.raw, self.frames) if frame.get("type") == frame_type]

    def wait(self, frame_type: str, count: int = 1, **fields) -> dict:
        def find():
            matches = [
                frame for frame in self.of(frame_type)
                if all(frame.get(key) == value for key, value in fields.items())
            ]
            return matches if len(matches) >= count else None
        return wait_until(find, message=f"{count} {frame_type} frame(s) {fields}")[count - 1]

    def close(self) -> None:
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


class RemoteContract:
    def connect(self) -> Device:
        device = Device(self.box.remote_sock)
        self.addCleanup(device.close)
        return device

    def hello(self, name: str = "hello_first_connect", **changes) -> Device:
        device = self.connect()
        device.send(vector_line(name, **changes))
        device.wait("welcome")
        return device

    def question_line(self, text: str = "what is the weather like") -> str:
        """An utterance that is a plain question: it raises only the messenger's answer."""
        return vector_line("utterance", client_id=str(uuid.uuid4()), text=text)

    def control_line(self, name: str) -> str:
        # The control vectors share one client id; a session drops a repeated id.
        return vector_line(name, client_id=str(uuid.uuid4()))

    def device_datagrams(self, state: str | None = None) -> list:
        return self.box.states(state, source="remote_device")

    # -- Connection --------------------------------------------------------

    def test_identify_status_probe_answers_and_closes(self):
        """Relay Remote: an `identify` line with `command: "status"` is answered
        with one `status` frame (`seq` 0, `running` while the bridge runs its
        loop) and the connection is closed."""
        device = self.connect()
        device.send(json.dumps({"type": "identify", "device_id": DEVICE_ID, "command": "status"}))
        self.assertTrue(device.closed.wait(WAIT_SECONDS))
        self.assertEqual(device.raw, [encoded({"seq": 0, "text": "running", "type": "status"})])

    def test_first_hello_is_welcomed_fresh(self):
        """Relay Remote: a first `hello` without `resume_after_seq` gets the
        `welcome_fresh` frame, with `session_state` `running` while the bridge
        runs, as one compact sorted-key JSON line."""
        device = self.hello("hello_first_connect")
        expected = json.loads(FRAMES["welcome_fresh"]["line"])
        expected["session_state"] = "running"
        self.assertEqual(device.raw_of("welcome"), [encoded(expected)])

    def test_identify_line_may_precede_hello(self):
        """Relay Remote: the helper's `identify` line for the same device may
        precede `hello`; a `hello` for another device is refused with
        `unsupported_protocol` and the connection closed."""
        device = self.connect()
        device.send(json.dumps({"type": "identify", "device_id": DEVICE_ID}))
        device.send(FRAMES["hello_first_connect"]["line"])
        device.wait("welcome")
        other = self.connect()
        other.send(json.dumps({"type": "identify", "device_id": "another-device"}))
        other.send(FRAMES["hello_first_connect"]["line"])
        self.assertEqual(other.wait("error")["code"], "unsupported_protocol")
        self.assertTrue(other.closed.wait(WAIT_SECONDS))

    def test_first_frame_must_be_hello(self):
        """Relay Remote: a valid frame other than `hello` before `hello` is
        refused with `hello_required` and the connection closed."""
        device = self.connect()
        device.send(FRAMES["ping"]["line"])
        self.assertEqual(device.wait("error")["code"], "hello_required")
        self.assertTrue(device.closed.wait(WAIT_SECONDS))
        self.assertFalse(device.of("pong"))

    def test_hello_with_another_protocol_is_refused(self):
        """Relay Remote: a `hello` whose `protocol` is not 1 is refused with
        `unsupported_protocol` and the connection closed."""
        device = self.connect()
        device.send(vector_line("hello_first_connect", protocol=2))
        self.assertEqual(device.wait("error")["code"], "unsupported_protocol")
        self.assertTrue(device.closed.wait(WAIT_SECONDS))
        self.assertFalse(device.of("welcome"))

    def test_invalid_frames_are_answered_with_their_error_code(self):
        """Relay Remote: every line of `invalid.json` is answered with an
        `error` frame carrying the vector's code, and the connection stays
        usable."""
        device = self.hello()
        for number, vector in enumerate(INVALID, start=1):
            device.send(vector["line"])
            error = device.wait("error", count=number)
            self.assertEqual(error["code"], vector["error"], vector["name"])
        device.send(FRAMES["ping"]["line"])
        device.wait("pong")

    def test_line_over_the_limit_is_refused_and_skipped(self):
        """Relay Remote: a line longer than `max_line_bytes` is answered with
        `line_too_long`, skipped whole, and the connection stays usable."""
        device = self.hello()
        padding = "x" * (LIMITS["max_line_bytes"] + 100)
        device.send(json.dumps({"type": "ping", "t": 1, "pad": padding}))
        self.assertEqual(device.wait("error")["code"], "line_too_long")
        device.send(FRAMES["ping"]["line"])
        device.wait("pong")
        self.assertEqual(len(device.of("error")), 1)

    def test_ping_is_answered_with_the_pong_vector(self):
        """Relay Remote: `ping` is answered with `pong` carrying the same `t`,
        byte for byte as the `pong` vector."""
        device = self.hello()
        device.send(FRAMES["ping"]["line"])
        device.wait("pong")
        self.assertEqual(device.raw_of("pong"), [FRAMES["pong"]["line"].encode("utf-8") + b"\n"])

    # -- Utterances and controls --------------------------------------------

    def test_utterance_is_accepted_as_the_newest_command(self):
        """Relay Remote: an `utterance` becomes the newest Relay command, with
        `input_source` `remote` and the device id, reaches the mailbox, and is
        answered with `accepted` naming that command."""
        device = self.hello()
        utterance = json.loads(FRAMES["utterance"]["line"])
        device.send(FRAMES["utterance"]["line"])
        accepted = device.wait("accepted")
        state = wait_until(
            lambda: self.session.state().get("relay_command_id") == accepted["relay_command_id"]
            and self.session.state(),
            message="the remote command in the state file",
        )
        self.assertEqual(accepted["client_id"], utterance["client_id"])
        self.assertEqual(accepted["relay_command_seq"], state["relay_command_seq"])
        self.assertEqual(state["source_text"], utterance["text"])
        self.assertEqual(state["input_source"], "remote")
        self.assertEqual(state["device_id"], DEVICE_ID)
        prompt, metadata = self.session.wait_pending()
        self.assertEqual(metadata["relay_command_id"], accepted["relay_command_id"])
        self.assertEqual(metadata["source_text"], utterance["text"])
        self.assertEqual(metadata["agent_prompt"], prompt)
        self.assertEqual(
            device.raw_of("accepted"),
            [encoded({
                "client_id": utterance["client_id"],
                "relay_command_id": accepted["relay_command_id"],
                "relay_command_seq": accepted["relay_command_seq"],
                "type": "accepted",
            })],
        )

    def test_retried_utterance_is_not_queued_twice(self):
        """Relay Remote: an utterance whose `client_id` was already accepted is
        not queued again; its `accepted` frame is sent again."""
        device = self.hello()
        device.send(FRAMES["utterance"]["line"])
        first = device.wait("accepted")
        device.send(FRAMES["utterance"]["line"])
        second = device.wait("accepted", count=2)
        self.assertEqual(first, second)
        self.assertStays(lambda: self.session.state()["relay_command_seq"] == first["relay_command_seq"])

    def test_utterance_naming_a_bridge_token_is_refused(self):
        """Relay Remote: utterance text that is empty or contains a reserved
        `__NAME__` token is refused with `invalid_utterance` and starts no
        command."""
        device = self.hello()
        for number, text in enumerate(("__CANCEL__", "please run __VOICE_TARGET__:x", "   "), start=1):
            device.send(vector_line("utterance", client_id=str(uuid.uuid4()), text=text))
            self.assertEqual(device.wait("error", count=number)["code"], "invalid_utterance")
        self.assertStays(lambda: self.session.state().get("relay_command_seq") is None)

    def test_controls_act_as_their_fifo_tokens(self):
        """Relay Remote: `control` actions act as FIFO tokens: `stop` as
        `__TTS_STOP__`, `cancel` as `__CANCEL__`, `play` as `__PLAY__`, `replay`
        as `__REPLAY__`; none starts a command."""
        device = self.hello()
        device.send(self.control_line("control_stop"))
        self.box.wait_speech_request("stop_playback", reason="recording_barge_in")
        device.send(self.control_line("control_cancel"))
        self.box.wait_speech_request("skip", reason="user_stop")
        device.send(self.control_line("control_play"))
        self.box.wait_speech_request("play_or_replay")
        device.send(self.control_line("control_replay"))
        self.box.wait_speech_request("replay")
        self.assertStays(lambda: self.session.state().get("relay_command_seq") is None)
        self.assertFalse(device.of("accepted"))

    def test_interrupt_control_publishes_an_interrupt_command(self):
        """Relay Remote: the `interrupt` control acts as `__INTERRUPT__`: speech
        stops with the reason `interrupt` and the `__INTERRUPT__` command
        reaches the mailbox."""
        device = self.hello()
        device.send(self.control_line("control_interrupt"))
        self.box.wait_speech_request("stop_playback", reason="interrupt")
        prompt, metadata = self.session.wait_pending()
        self.assertEqual(prompt, "__INTERRUPT__")
        self.assertEqual(metadata["action"], "control")

    # -- Speech sink and mirror ---------------------------------------------

    def test_hello_attaches_the_device_as_speech_sink(self):
        """Relay Remote: `hello` (Remote mode on or absent) attaches the device
        as the speech `sink` and posts a `remote_device` `active` datagram with
        its id and name."""
        self.hello()
        self.box.wait_speech_request("remote_attach", device_id=DEVICE_ID, role="sink")
        datagram = wait_until(lambda: self.device_datagrams("active"), message="the active datagram")[-1]
        self.assertEqual(datagram["device_id"], DEVICE_ID)
        self.assertEqual(datagram["device_name"], "iPhone")

    def test_remote_mode_off_moves_the_device_to_mirror(self):
        """Relay Remote: `remote_mode` off detaches the sink (reason
        `remote_mode_off`), attaches the device as `mirror` and posts
        `inactive`; on again attaches it as `sink` and posts `active`."""
        device = self.hello()
        self.box.wait_speech_request("remote_attach", device_id=DEVICE_ID, role="sink")
        device.send(FRAMES["remote_mode_off"]["line"])
        self.box.wait_speech_request("remote_detach", device_id=DEVICE_ID, role="sink", reason="remote_mode_off")
        self.box.wait_speech_request("remote_attach", device_id=DEVICE_ID, role="mirror")
        wait_until(lambda: self.device_datagrams("inactive"), message="the inactive datagram")
        before = len([r for r in self.box.speech_requests("remote_attach") if r["role"] == "sink"])
        device.send(FRAMES["remote_mode_on"]["line"])
        wait_until(
            lambda: len([r for r in self.box.speech_requests("remote_attach") if r["role"] == "sink"]) > before,
            message="the device attached as sink again",
        )
        wait_until(lambda: len(self.device_datagrams("active")) >= 2, message="a second active datagram")

    def test_hello_with_remote_mode_off_attaches_a_mirror(self):
        """Relay Remote: a `hello` with `remote_mode: false` attaches the device
        as `mirror` only and posts `inactive`."""
        self.hello("hello_remote_mode_off")
        self.box.wait_speech_request("remote_attach", device_id=DEVICE_ID, role="mirror")
        wait_until(lambda: self.device_datagrams("inactive"), message="the inactive datagram")
        self.assertFalse(
            [r for r in self.box.speech_requests("remote_attach") if r["role"] == "sink"]
        )

    def test_speech_for_a_sink_reaches_the_device_as_speech_frames(self):
        """Relay Remote: speech accepted while a sink is attached reaches the
        device as `speech` frames numbered from 1, carrying the request's
        `kind`, `source`, `text` and command seq, with `spoken_by` `phone`."""
        device = self.hello()
        self.box.wait_speech_request("remote_attach", device_id=DEVICE_ID, role="sink")
        device.send(self.question_line())
        accepted = device.wait("accepted")
        frame = device.wait("speech", source="messenger")
        speak = self.box.wait_spoken(source="messenger")
        self.assertEqual(frame["seq"], 1)
        self.assertEqual(frame["kind"], speak["kind"])
        self.assertEqual(frame["text"], speak["text"])
        self.assertEqual(frame["relay_command_seq"], accepted["relay_command_seq"])
        self.assertEqual(frame["spoken_by"], "phone")
        raw = device.raw_of("speech")[0]
        self.assertEqual(raw, encoded(frame))

    def test_ack_is_passed_to_speech(self):
        """Relay Remote: an `ack` frame becomes a speech `remote_ack` with the
        device id, `seq` and `played`."""
        device = self.hello()
        device.send(self.question_line())
        frame = device.wait("speech")
        device.send(json.dumps({"type": "ack", "seq": frame["seq"], "played": True}))
        ack = self.box.wait_speech_request("remote_ack", device_id=DEVICE_ID)
        self.assertEqual((ack["seq"], ack["played"]), (frame["seq"], True))

    def test_reconnect_replays_the_speech_it_missed(self):
        """Relay Remote: speech for a disconnected device in Remote mode is kept;
        a `hello` with `resume_after_seq` is welcomed with `resumed_from` and the
        newest `server_seq`, followed by the missed frames in order. The
        disconnect posts a `remote_device` `disconnected` datagram."""
        device = self.hello()
        device.send(self.question_line())
        first = device.wait("speech")
        self.assertStays(lambda: len(device.of("speech")) == 1)
        device.close()
        wait_until(lambda: self.device_datagrams("disconnected"), message="the disconnected datagram")
        self.box.say("tell me about the release")
        missed = self.box.wait_spoken(source="messenger", text="Messenger heard: tell me about the release")
        wait_until(
            lambda: [
                record for record in self.box.speech_records()
                if record.get("record") == "call" and record["fields"].get("text") == missed["text"]
            ],
            message="the missed speech sent to the device session",
        )
        again = self.connect()
        again.send(vector_line("hello", resume_after_seq=first["seq"]))
        welcome = again.wait("welcome")
        self.assertEqual(welcome["resumed_from"], first["seq"])
        self.assertEqual(welcome["server_seq"], first["seq"] + 1)
        self.assertIs(welcome["dropped"], False)
        replayed = again.wait("speech")
        self.assertEqual(replayed["seq"], first["seq"] + 1)
        self.assertEqual(replayed["text"], missed["text"])
        self.assertLess(
            [frame["type"] for frame in again.frames].index("welcome"),
            [frame["type"] for frame in again.frames].index("speech"),
        )


class ClaudeRemote(RemoteContract, BridgeCase):
    provider = "claude"


class CodexRemote(RemoteContract, BridgeCase):
    provider = "codex"


RUST_REMOTE = REPO_ROOT / "rust" / "target" / "release" / "relay-rs"
rust_remote = unittest.skipUnless(
    BRIDGE_IS_REFERENCE and os.access(RUST_REMOTE, os.X_OK),
    "needs the reference bridge and a relay-rs release build (cargo build --release in rust/)",
)
RUST_REMOTE_ENV = {"RELAY_REMOTE_RUNTIME": "rust", "RELAY_RS_BIN": str(RUST_REMOTE)}


@rust_remote
class ClaudeRustRemote(RemoteContract, BridgeCase):
    provider = "claude"
    env = RUST_REMOTE_ENV


@rust_remote
class CodexRustRemote(RemoteContract, BridgeCase):
    provider = "codex"
    env = RUST_REMOTE_ENV


if __name__ == "__main__":
    unittest.main()
