"""Voice bridge contract: environment switches that change how a command is
routed or recorded (docs/specs/voice-bridge-contract.md, "Environment")."""

from __future__ import annotations

import json
import unittest

from bridge_contract_support import BridgeCase

CHANGE_REQUEST = "fix the login button colour"


class WorkStyleContract:
    def start_with(self, **env) -> None:
        self.box.extra_env.update(env)
        self.box.start()

    def setUp(self):
        self.start_bridge = False
        super().setUp()

    def test_auto_leaves_a_change_request_undecided(self):
        """Environment: with no work style set, a change request without a
        route signal is a `conversation` with the qualification `undecided` /
        `route_undecided`, for the PM to route."""
        self.start_with()
        command = self.turn(CHANGE_REQUEST)
        self.assertEqual(command["action"], "conversation")
        self.assertEqual(command["intent_qualification"]["bucket"], "undecided")
        self.assertEqual(command["intent_qualification"]["reason"], "route_undecided")

    def test_relay_work_style_direct_makes_a_change_request_inline_work(self):
        """Environment: `RELAY_WORK_STYLE=direct` makes the same request
        `inline_work`, qualified as an `action` for `work_style_direct`, and the
        agent prompt names the direct work style."""
        self.start_with(RELAY_WORK_STYLE="direct")
        command = self.turn(CHANGE_REQUEST)
        self.assertEqual(command["action"], "inline_work")
        self.assertEqual(command["intent_qualification"]["bucket"], "action")
        self.assertEqual(command["intent_qualification"]["reason"], "work_style_direct")
        self.assertIn("- work_style: direct", command["agent_prompt"])

    def test_the_session_work_style_file_applies_and_the_variable_wins(self):
        """Environment: the session choice saved at
        `RELAY_SESSION_WORK_STYLE_FILE` (`{"work_style": "direct"}`) applies
        when `RELAY_WORK_STYLE` is unset; `RELAY_WORK_STYLE` overrides it."""
        saved = self.box.root / "session-work-style.json"
        saved.write_text(json.dumps({"work_style": "direct"}))
        self.start_with(RELAY_SESSION_WORK_STYLE_FILE=str(saved))
        self.assertEqual(self.turn(CHANGE_REQUEST)["action"], "inline_work")
        self.box.stop()
        self.start_with(RELAY_WORK_STYLE="orchestrated")
        self.assertEqual(self.turn("fix the logout button colour")["action"], "create_ticket")


class GeneralScopeContract:
    def setUp(self):
        self.start_bridge = False
        super().setUp()

    def test_a_general_session_keeps_ticket_work_off_the_project(self):
        """Environment: with `RELAY_SESSION_SCOPE=general` and the working
        directory at `RELAY_GENERAL_FILES_ROOT`, a ticket request is general
        work: no `repo_path`, outcome `general work needs refined ticket`."""
        self.box.extra_env.update(RELAY_SESSION_SCOPE="general", RELAY_GENERAL_FILES_ROOT=str(self.box.repo))
        self.box.start()
        command = self.turn("create a ticket to write the quarterly newsletter")
        self.assertEqual(command["action"], "create_ticket")
        self.assertIsNone(command.get("repo_path"))
        self.assertEqual(command["outcome"], "general work needs refined ticket")


class TurnBrokerModeContract:
    def setUp(self):
        self.start_bridge = False
        super().setUp()

    def test_the_turn_projection_is_written_unless_the_broker_is_legacy(self):
        """Environment: by default (`dual_write`) the bridge writes the v2 turn
        projection at `VOICE_PROVIDER_TURN_PROJECTION_FILE`
        (`schema_version: 2`); `RELAY_PROVIDER_TURN_BROKER_MODE=legacy` writes
        none."""
        self.box.start()
        self.claimed_turn("summarise the incident")
        self.assertEqual(self.box.turn_projection.exists(), True)
        self.assertEqual(json.loads(self.box.turn_projection.read_text())["schema_version"], 2)
        self.box.stop()
        self.box.turn_projection.unlink()
        self.box.extra_env.update(RELAY_PROVIDER_TURN_BROKER_MODE="legacy")
        self.box.start()
        self.claimed_turn("summarise the outage")
        self.assertStays(lambda: not self.box.turn_projection.exists())


class ConfigOverrideContract:
    def setUp(self):
        self.start_bridge = False
        super().setUp()

    def test_a_setting_missing_from_the_config_file_comes_from_the_environment(self):
        """Environment: a `config.toml` key that is absent is read from
        `VOICE_TERMINAL_<SECTION>_<KEY>`; with `messenger_enabled` left out and
        `VOICE_TERMINAL_GENERAL_MESSENGER_ENABLED=false` the messenger stays
        silent."""
        self.box.config_path.write_text(
            self.box.config_path.read_text().replace("messenger_enabled = true\n", ""))
        self.box.extra_env.update(VOICE_TERMINAL_GENERAL_MESSENGER_ENABLED="false")
        self.box.start()
        command = self.turn("is anyone there")
        self.session.wait_pending()
        self.assertStays(lambda: not self.box.spoken(command_id=command["relay_command_id"]))
        self.assertFalse(self.box.messenger_prompts())


class ClaudeWorkStyle(WorkStyleContract, BridgeCase):
    provider = "claude"


class CodexWorkStyle(WorkStyleContract, BridgeCase):
    provider = "codex"


class ClaudeGeneralScope(GeneralScopeContract, BridgeCase):
    provider = "claude"


class CodexGeneralScope(GeneralScopeContract, BridgeCase):
    provider = "codex"


class ClaudeTurnBrokerMode(TurnBrokerModeContract, BridgeCase):
    provider = "claude"


class CodexTurnBrokerMode(TurnBrokerModeContract, BridgeCase):
    provider = "codex"


class ClaudeConfigOverride(ConfigOverrideContract, BridgeCase):
    provider = "claude"


class CodexConfigOverride(ConfigOverrideContract, BridgeCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
