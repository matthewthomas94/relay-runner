"""RR-394: the bridge publishes into the targeted session spool."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVICES = os.path.join(ROOT, "services")

_PATHS = """
import json, sys, types
sys.path.insert(0, sys.argv[1])
sys.modules.setdefault("numpy", types.SimpleNamespace(asarray=lambda s: s, int16=object()))
import voice_bridge as vb
print(json.dumps({
    "cmd": vb.VOICE_CMD_FILE, "meta": vb.VOICE_CMD_META_FILE,
    "state": vb.VOICE_COMMAND_STATE_FILE, "claim": vb.VOICE_COMMAND_CLAIM_FILE,
    "ack": vb.VOICE_MANUAL_CLAIM_ACK_FILE, "auth": vb.VOICE_COMMAND_AUTHORIZATION_FILE,
    "mirrored": vb._MIRRORED_COMMAND_STATE_FILE,
}))
"""


def _resolved_paths(**env: str) -> dict:
    clean = {k: v for k, v in os.environ.items()
             if not k.startswith(("VOICE_", "RELAY_SESSION_"))}
    clean.update(env)
    output = subprocess.check_output([sys.executable, "-c", _PATHS, SERVICES], env=clean)
    return json.loads(output)


class SessionSpoolPathTests(unittest.TestCase):
    def test_manual_session_keeps_legacy_tmp_files(self):
        paths = _resolved_paths()
        self.assertEqual(paths["cmd"], "/tmp/voice_cmd_ready")
        self.assertEqual(paths["state"], "/tmp/voice_command_state.json")
        self.assertIsNone(paths["mirrored"])

    def test_spool_directory_scopes_handoff_files_and_keeps_ledger_shared(self):
        paths = _resolved_paths(RELAY_SESSION_SPOOL_DIR="/tmp/relay-sessions/abc")
        self.assertEqual(paths["cmd"], "/tmp/relay-sessions/abc/voice_cmd_ready")
        self.assertEqual(paths["meta"], "/tmp/relay-sessions/abc/voice_cmd_ready.meta")
        self.assertEqual(paths["state"], "/tmp/relay-sessions/abc/voice_command_state.json")
        self.assertEqual(paths["claim"], "/tmp/relay-sessions/abc/voice_cmd_claimed.json")
        self.assertEqual(paths["ack"], "/tmp/relay-sessions/abc/voice_cmd_manual_ack.json")
        self.assertEqual(paths["auth"], "/tmp/voice_command_authorizations.json")
        self.assertEqual(paths["mirrored"], paths["state"])

    def test_explicit_file_override_wins(self):
        paths = _resolved_paths(
            RELAY_SESSION_SPOOL_DIR="/tmp/relay-sessions/abc",
            VOICE_CMD_FILE="/tmp/custom_cmd",
        )
        self.assertEqual(paths["cmd"], "/tmp/custom_cmd")
        self.assertEqual(paths["meta"], "/tmp/custom_cmd.meta")


class CommandStateMirrorTests(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, SERVICES)
        import types
        sys.modules.setdefault("numpy", types.SimpleNamespace(asarray=lambda s: s, int16=object()))
        import voice_bridge
        self.vb = voice_bridge
        self.addCleanup(sys.path.remove, SERVICES)

    def test_only_the_targeted_spool_state_is_mirrored_for_the_daemon(self):
        with tempfile.TemporaryDirectory() as root:
            spool_state = os.path.join(root, "spool_state.json")
            other_state = os.path.join(root, "other_state.json")
            legacy = os.path.join(root, "legacy_state.json")
            with mock.patch.object(self.vb, "_MIRRORED_COMMAND_STATE_FILE", spool_state), \
                    mock.patch.object(self.vb, "LEGACY_VOICE_COMMAND_STATE_FILE", legacy):
                self.vb._atomic_write_json(other_state, {"relay_command_seq": 1})
                self.assertFalse(os.path.exists(legacy))
                self.vb._atomic_write_json(spool_state, {"relay_command_seq": 2})
                with open(legacy) as f:
                    self.assertEqual(json.load(f), {"relay_command_seq": 2})


if __name__ == "__main__":
    unittest.main()
