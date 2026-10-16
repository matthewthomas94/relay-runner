"""RR-399: the daemon resolves a mutation's command state per session.

Background sessions run concurrently, each with its own spool under
/tmp/relay-sessions/<key>. A mutation names its session key; the daemon must
check that session's state file and ledger records only, while manual
single-session bridges keep the legacy /tmp paths. The check is provider
neutral, so Codex and Claude sessions take the identical path.
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))

import orchestrator
from relay_authorization import record_command_authorization

DISPATCH = {"kind": "dispatch_ticket", "ticket_ids": ["RR-1"]}


class SessionScopedRelayAuthorizationTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.spools = self.root / "relay-sessions"
        self.ledger = self.root / "authorizations.json"
        self.legacy_state = self.root / "voice_command_state.json"
        for name, value in (("RELAY_SESSION_SPOOL_ROOT", self.spools),
                            ("RELAY_COMMAND_STATE_FILE", self.legacy_state),
                            ("RELAY_COMMAND_AUTHORIZATION_FILE", self.ledger)):
            replacement = patch.object(orchestrator, name, value)
            replacement.start()
            self.addCleanup(replacement.stop)

    def publish(self, key, seq, command_id, *, relationship="additive", scope=None):
        """Mirror the bridge: record the grant, then make it the session's newest."""
        command = {"relay_command_seq": seq, "relay_command_id": command_id,
                   "intent_id": f"intent-{command_id}"}
        if scope:
            command["cancellation_scope"] = scope
        record_command_authorization(self.ledger, command, relationship=relationship,
                                     allowed_mutations=[] if scope else [DISPATCH],
                                     session_key=key, now=seq)
        if key:
            state = self.spools / key / "voice_command_state.json"
            state.parent.mkdir(parents=True, exist_ok=True)
        else:
            state = self.legacy_state
        state.write_text(json.dumps(command))
        return command

    def dispatch(self, command, key):
        orchestrator._validate_relay_command(
            command["relay_command_seq"], command["relay_command_id"],
            relay_intent_id=command["intent_id"],
            mutation=orchestrator._relay_mutation_metadata("dispatch_ticket", ticket_id="RR-1"),
            relay_session_key=key,
        )

    def test_session_a_mutation_accepted_while_session_b_is_newer(self):
        a = self.publish("session-a", 10, "cmd-a")
        self.publish("session-b", 11, "cmd-b")
        self.dispatch(a, "session-a")
        record = next(item for item in json.loads(self.ledger.read_text())["authorizations"]
                      if item["relay_command_id"] == "cmd-a")
        self.assertEqual(record["relay_session_key"], "session-a")
        self.assertEqual(len(record["started_mutations"]), 1)

    def test_session_a_cannot_use_session_b_command(self):
        self.publish("session-a", 10, "cmd-a")
        b = self.publish("session-b", 11, "cmd-b")
        with self.assertRaisesRegex(ValueError, "no mutation authorization was registered"):
            self.dispatch(b, "session-a")
        # Non-mutating freshness checks are also judged against A's own state.
        with self.assertRaisesRegex(ValueError, "stale Relay command"):
            orchestrator._validate_relay_command(11, "cmd-b", relay_session_key="session-a")
        self.dispatch(b, "session-b")

    def test_missing_session_spool_never_falls_back_to_legacy_state(self):
        legacy = self.publish("", 10, "cmd-manual")
        with self.assertRaisesRegex(ValueError, "stale Relay command"):
            orchestrator._validate_relay_command(10, "cmd-manual", relay_session_key="session-gone")
        with self.assertRaisesRegex(ValueError, "no mutation authorization was registered"):
            self.dispatch(legacy, "session-gone")

    def test_manual_bridge_keeps_legacy_paths(self):
        first = self.publish("", 10, "cmd-manual")
        self.dispatch(first, None)
        second = self.publish("", 11, "cmd-manual-2")
        orchestrator._validate_relay_command(11, "cmd-manual-2")
        with self.assertRaisesRegex(ValueError, "stale Relay command"):
            orchestrator._validate_relay_command(10, "cmd-manual")
        self.dispatch(second, "")

    def test_all_work_cancellation_is_scoped_to_its_session(self):
        a = self.publish("session-a", 10, "cmd-a")
        b = self.publish("session-b", 11, "cmd-b")
        self.publish("session-b", 12, "cancel-b", relationship="cancel", scope="all_work")
        with self.assertRaisesRegex(ValueError, "authorization was revoked"):
            self.dispatch(b, "session-b")
        self.dispatch(a, "session-a")

    def test_invalid_session_key_is_rejected(self):
        a = self.publish("session-a", 10, "cmd-a")
        for key in ("../session-a", "Session-A", "a/b", "x" * 65):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "invalid relay_session_key"):
                self.dispatch(a, key)

    def test_untrusted_spool_symlink_is_never_current(self):
        a = self.publish("session-a", 10, "cmd-a")
        (self.spools / "session-link").symlink_to(self.spools / "session-a")
        with self.assertRaisesRegex(ValueError, "stale Relay command"):
            orchestrator._validate_relay_command(10, "cmd-a", relay_session_key="session-link")
        self.assertIsNone(orchestrator._relay_command_state_file("session-link"))
        self.dispatch(a, "session-a")


if __name__ == "__main__":
    unittest.main()
