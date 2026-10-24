"""RR-430: Relay Remote end to end over a real loopback SSH connection.

Runs a per-user sshd on a high port with a throwaway host key and a
forced-command authorized_keys entry, the real ``relay-remote-shell`` helper,
the real bridge relay loop and RelayRemoteServer, and a SpeechCoordinator as
the remote sink. A scripted device drives it through ``ssh``. Everything lives
in one temp directory; keys are generated at test time.

The helper comes from ``RELAY_REMOTE_SHELL`` or ``.build/debug/relay-remote-shell``
(``swift build --product relay-remote-shell``).
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "services"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import relay_remote_protocol as proto  # noqa: E402
from speech_coordinator import SpeechCoordinator  # noqa: E402
import test_relay_remote as remote_tests  # noqa: E402
import test_speech_coordinator as coordinator_tests  # noqa: E402

wait_until = remote_tests.wait_until
SSHD = "/usr/sbin/sshd"
CLIENT_ID = "6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f"
HELPER = os.environ.get("RELAY_REMOTE_SHELL") or os.path.join(ROOT, ".build", "debug", "relay-remote-shell")


class SSHDevice:
    """A scripted phone: NDJSON frames over one real ssh connection."""

    def __init__(self, argv: list[str]):
        self.proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
        )
        self.lines: queue.Queue[bytes] = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self) -> None:
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(b"")

    def send(self, frame) -> None:
        self.proc.stdin.write(proto.encode(frame))
        self.proc.stdin.flush()

    def recv(self, timeout: float = 8.0):
        line = self.lines.get(timeout=timeout)
        if not line:
            raise EOFError("connection closed")
        return proto.decode(line)

    def hello(self, device_id: str = "phone-1", resume_after_seq=None):
        self.send(proto.Hello(device_id, "iPhone", "0.1", resume_after_seq))
        return self.recv()

    def close(self) -> None:
        for stream in (self.proc.stdin, self.proc.stdout):
            try:
                stream.close()
            except OSError:
                pass
        self.proc.kill()
        self.proc.wait()


@unittest.skipUnless(os.path.exists(SSHD) and shutil.which("ssh") and shutil.which("ssh-keygen"), "OpenSSH not installed")
@unittest.skipUnless(os.access(HELPER, os.X_OK), "relay-remote-shell not built")
class RelayRemoteLoopbackTests(remote_tests.BridgeRemoteIngressTests):
    def setUp(self):
        self.now = 1000.0
        self.current: set[tuple[int, str]] = set()
        # Starts the real bridge relay loop on the real server (self.server, .published).
        super().setUp()
        self.start_sshd()

    def start_server(self, *, attached: bool = True, **kwargs):
        self.log = Path(self.root) / "speech-events.jsonl"
        self.coordinator = SpeechCoordinator(
            coordinator_tests.FakeWorker(),
            is_current=lambda seq, command_id: (seq, command_id) in self.current,
            event_log_path=self.log,
        )
        return super().start_server(
            attached=attached, speech=self.coordinator, clock=lambda: self.now, **kwargs
        )

    def start_sshd(self) -> None:
        # Unix socket paths are short; keep sshd files beside the bridge socket.
        tmp = Path(self.root)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        for name in ("host_key", "client_key"):
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(tmp / name)], check=True
            )
        # sshd runs command= through a shell, so link the helper at a space-free path.
        os.symlink(HELPER, tmp / "relay-remote-shell")
        public = (tmp / "client_key.pub").read_text().split()[:2]
        authorized = tmp / "authorized_keys"
        authorized.write_text(
            f'command="{tmp}/relay-remote-shell --device phone-1",restrict {" ".join(public)}\n'
        )
        authorized.chmod(0o600)
        (tmp / "sshd_config").write_text("\n".join([
            f"Port {port}",
            "ListenAddress 127.0.0.1",
            f"HostKey {tmp}/host_key",
            f"AuthorizedKeysFile {authorized}",
            f"PidFile {tmp}/sshd.pid",
            "StrictModes no",
            "UsePAM no",
            "PasswordAuthentication no",
            "KbdInteractiveAuthentication no",
            "PubkeyAuthentication yes",
            f"SetEnv RELAY_REMOTE_SOCKET_PATH={self.path}",
            "LogLevel ERROR",
            "",
        ]))
        sshd = subprocess.Popen(
            [SSHD, "-D", "-f", str(tmp / "sshd_config")],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.addCleanup(lambda: (sshd.kill(), sshd.wait()))
        self.ssh_argv = [
            "ssh", "-p", str(port), "-i", str(tmp / "client_key"),
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "127.0.0.1",
        ]
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)

    def ssh_device(self) -> SSHDevice:
        device = SSHDevice(self.ssh_argv)
        self.addCleanup(device.close)
        return device

    def events(self, name: str) -> list[dict]:
        if not self.log.exists():
            return []
        records = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [record for record in records if record["event"] == name]

    def connect(self, resume_after_seq=None):
        device = self.ssh_device()
        welcome = device.hello("phone-1", resume_after_seq)
        self.assertTrue(wait_until(lambda: "phone-1" in self.coordinator._remote_sinks))
        return device, welcome

    def test_phone_session_over_real_ssh(self):
        # hello is answered with welcome.
        device, welcome = self.connect()
        self.assertEqual(welcome, proto.Welcome(session_state="running", server_seq=0, dropped=False))

        # An utterance is accepted and reaches the bridge command path.
        device.send(remote_tests.utterance("open the board", CLIENT_ID))
        accepted = device.recv()
        self.assertIsInstance(accepted, proto.Accepted)
        self.assertEqual(accepted.client_id, CLIENT_ID)
        self.assertTrue(wait_until(lambda: any(
            m["relay_command_seq"] == accepted.relay_command_seq
            and m["source_text"] == "open the board"
            and m.get("input_source") == "remote"
            and m.get("device_id") == "phone-1"
            for m in self.published
        )))

        # The coordinator emits a speech frame to the device.
        command = (accepted.relay_command_seq, accepted.relay_command_id)
        self.current.add(command)
        self.coordinator.submit(coordinator_tests.intent(
            seq=command[0], command_id=command[1], kind="handoff", text="Looking now"
        ))
        speech = device.recv()
        self.assertIsInstance(speech, proto.Speech)
        self.assertEqual((speech.text, speech.kind, speech.relay_command_seq), ("Looking now", "handoff", command[0]))

        # A played ack is recorded as a realization.
        device.send(proto.Ack(speech.seq, True))
        self.assertTrue(wait_until(lambda: self.events("realization")))
        realization = self.events("realization")[0]
        self.assertEqual(
            (realization["relay_command_seq"], realization["relay_command_id"]), command
        )

        # Frames produced during a disconnect replay in order on reconnect.
        device.close()
        self.assertTrue(wait_until(lambda: self.server.session("phone-1").conn is None))
        self.coordinator.submit(coordinator_tests.intent(
            seq=command[0], command_id=command[1], kind="progress", text="While away"
        ))
        self.coordinator.submit(coordinator_tests.intent(
            seq=command[0], command_id=command[1], kind="final", authoritative=True, text="Result"
        ))
        again, welcome = self.connect(resume_after_seq=speech.seq)
        self.assertEqual((welcome.server_seq, welcome.dropped), (speech.seq + 2, False))
        missed = [again.recv(), again.recv()]
        self.assertEqual([f.seq for f in missed], [speech.seq + 1, speech.seq + 2])
        self.assertEqual([f.text for f in missed], ["While away", "Result"])

    # Inherited from the bridge ingress suite; they run there, not over SSH.
    test_fifo_and_remote_commands_share_one_ordered_sequence = None
    test_remote_controls_reach_the_fifo_control_path = None


if __name__ == "__main__":
    unittest.main()
