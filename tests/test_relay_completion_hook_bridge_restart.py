"""RR-465: a bridge restart mid-turn must not lose the spoken final reply."""

from __future__ import annotations

import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))

import relay_completion_hook  # noqa: E402

OWNERSHIP = {
    "app_session_id": "app-session",
    "recovery_generation": "generation-1",
    "actor_role": "foreground_pm",
    "foreground_gate_handle": "gate-1",
}


class CompletionAfterBridgeRestartTests(unittest.TestCase):
    def _env(self, provider: str) -> dict:
        return {
            "RELAY_APP_SESSION_ID": OWNERSHIP["app_session_id"],
            "RELAY_RECOVERY_GENERATION": OWNERSHIP["recovery_generation"],
            "RELAY_ACTOR_ROLE": OWNERSHIP["actor_role"],
            "RELAY_FOREGROUND_GATE_HANDLE": OWNERSHIP["foreground_gate_handle"],
            "RELAY_RUNNER_PROVIDER": provider,
            "RELAY_PROVIDER_SESSION_ID": f"provider-session-{provider}",
        }

    def test_stop_after_v1_ledger_removed_still_delivers_final(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp:
                state_path = os.path.join(temp, "voice_command_state.json")
                claim_path = os.path.join(temp, "voice_cmd_claimed.json")
                turns_path = os.path.join(temp, "voice_provider_turns.json")
                native_turn = (
                    {"turn_id": "native-turn-1"} if provider == "codex" else {"prompt_id": "prompt-1"}
                )
                command = {
                    "relay_command_seq": 173,
                    "relay_command_id": f"command-{provider}-173",
                    "intent_id": "intent-173",
                    "agent_prompt": "bounded prompt",
                    "provider": provider,
                }
                Path(state_path).write_text(json.dumps(command))
                Path(claim_path).write_text(json.dumps(command))
                delivered: list[dict] = []
                with mock.patch.dict(os.environ, self._env(provider)):
                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        {
                            "hook_event_name": "UserPromptSubmit",
                            "session_id": f"native-session-{provider}",
                            "prompt": "bounded prompt",
                            **native_turn,
                        },
                        claim_path=claim_path,
                        state_path=state_path,
                        turns_path=turns_path,
                        stderr=io.StringIO(),
                    ))
                    # The watchdog restarts the bridge while the turn runs.
                    os.unlink(turns_path)
                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        {
                            "hook_event_name": "Stop",
                            "session_id": f"native-session-{provider}",
                            "stop_hook_active": False,
                            "last_assistant_message": "the final reply",
                            **native_turn,
                        },
                        state_path=state_path,
                        turns_path=turns_path,
                        write_control=lambda payload: delivered.append(payload) or True,
                        stderr=io.StringIO(),
                    ))

                self.assertEqual(len(delivered), 1)
                self.assertEqual(delivered[0]["text"], "the final reply")
                self.assertEqual(delivered[0]["relay_command_seq"], 173)
                self.assertEqual(delivered[0]["intent_id"], "intent-173")
                with sqlite3.connect(turns_path + ".sqlite3") as connection:
                    self.assertEqual(
                        connection.execute("SELECT state FROM provider_turns").fetchall(),
                        [("completed_final",)],
                    )
                records = json.loads(Path(turns_path).read_text())["records"]
                self.assertEqual([r["state"] for r in records], ["completed_final"])
                self.assertEqual(records[0]["delivery"], "sent")

    def test_broker_fallback_ignores_other_native_sessions(self):
        with tempfile.TemporaryDirectory() as temp:
            state_path = os.path.join(temp, "voice_command_state.json")
            claim_path = os.path.join(temp, "voice_cmd_claimed.json")
            turns_path = os.path.join(temp, "voice_provider_turns.json")
            command = {
                "relay_command_seq": 1,
                "relay_command_id": "command-1",
                "intent_id": "intent-1",
                "agent_prompt": "prompt",
                "provider": "codex",
            }
            Path(state_path).write_text(json.dumps(command))
            Path(claim_path).write_text(json.dumps(command))
            delivered: list[dict] = []
            with mock.patch.dict(os.environ, self._env("codex")):
                relay_completion_hook.handle_hook_payload(
                    {"hook_event_name": "UserPromptSubmit", "session_id": "native-a",
                     "prompt": "prompt", "turn_id": "turn-1"},
                    claim_path=claim_path, state_path=state_path, turns_path=turns_path,
                    stderr=io.StringIO(),
                )
                os.unlink(turns_path)
                self.assertFalse(relay_completion_hook.handle_hook_payload(
                    {"hook_event_name": "Stop", "session_id": "native-b",
                     "last_assistant_message": "wrong session", "turn_id": "turn-1"},
                    state_path=state_path, turns_path=turns_path,
                    write_control=lambda payload: delivered.append(payload) or True,
                    stderr=io.StringIO(),
                ))
            self.assertEqual(delivered, [])


if __name__ == "__main__":
    unittest.main()
