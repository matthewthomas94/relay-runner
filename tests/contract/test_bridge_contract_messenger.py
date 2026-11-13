"""Voice bridge contract: the persistent messenger on both providers (Claude
stream-json, Codex app-server JSON-RPC), driven by the scripted fakes
(docs/specs/voice-bridge-contract.md, "Messenger")."""

from __future__ import annotations

import unittest

from bridge_contract_support import (
    MESSENGER_DEGRADED_TEXT,
    BridgeCase,
    wait_until,
)


class MessengerContract:
    def messenger_speech(self, command: dict) -> list:
        return [request for request in self.box.spoken(command_id=command["relay_command_id"])
                if request.get("source") in ("messenger", "fallback")]

    def test_messenger_is_started_tool_free_on_the_configured_provider(self):
        """Messenger: the bridge starts the configured provider as a tool-free
        messenger: Claude with `--print` stream-json, no tools, no MCP servers
        and no slash commands; Codex as `app-server --stdio` with tools and MCP
        servers off and one ephemeral read-only thread. The child gets
        `RELAY_ACTOR_ROLE=messenger` and none of the foreground-only variables."""
        launch = wait_until(
            lambda: [record for record in self.box.messenger_records("launch")
                     if record["argv"][:2] != ["auth", "status"] and "features.hooks=false" in record["argv"]
                     or "--input-format" in record["argv"]],
            message="the messenger launch",
        )[0]
        argv = launch["argv"]
        if self.provider == "claude":
            for flag in ("--print", "--disable-slash-commands", "--strict-mcp-config"):
                self.assertIn(flag, argv)
            self.assertEqual(argv[argv.index("--input-format") + 1], "stream-json")
            self.assertEqual(argv[argv.index("--output-format") + 1], "stream-json")
            self.assertEqual(argv[argv.index("--tools") + 1], "")
            self.assertEqual(argv[argv.index("--mcp-config") + 1], '{"mcpServers":{}}')
        else:
            self.assertEqual(argv[:2], ["app-server", "--stdio"])
            for setting in ("features.shell_tool=false", "features.apps=false", "features.hooks=false",
                            "tools.web_search=false", "mcp_servers={}"):
                self.assertIn(setting, argv)
            thread = wait_until(lambda: self.box.messenger_records("thread"), message="thread/start")[0]["params"]
            self.assertIs(thread["ephemeral"], True)
            self.assertEqual(thread["sandbox"], "read-only")
            self.assertEqual(thread["approvalPolicy"], "never")
            self.assertEqual(thread["dynamicTools"], [])
        self.assertEqual(launch["env"].get("RELAY_ACTOR_ROLE"), "messenger")
        for name in ("RELAY_PROVIDER_SESSION_ID", "RELAY_RUNNER_APP_SESSION", "RELAY_RECOVERY_GENERATION"):
            self.assertNotIn(name, launch["env"])

    def test_user_turn_reaches_the_messenger_and_its_handoff_is_spoken(self):
        """Messenger: each user turn is a `user_turn` prompt whose context ends
        with `USER: <text>`. A reply prefixed `__HANDOFF__` is spoken without the
        prefix as a `handoff` from `messenger`, an acknowledgement of the
        command."""
        command = self.turn("look into the flaky upload test")
        prompt = self.box.wait_messenger_prompt("user_turn", "look into the flaky upload test")
        self.assertIn("USER: look into the flaky upload test", prompt["prompt"])
        spoken = self.box.wait_spoken(text="Messenger heard: look into the flaky upload test")
        self.assertEqual((spoken["source"], spoken["kind"]), ("messenger", "handoff"))
        self.assertEqual(spoken["lifecycle_role"], "acknowledgement")
        self.assertEqual(spoken["command_id"], command["relay_command_id"])
        self.assertIs(spoken["authoritative"], False)

    def test_an_answer_is_spoken_as_conversation(self):
        """Messenger: a reply prefixed `__ANSWER__` is spoken as `conversation`."""
        self.box.script_messenger([{"when": "hello there", "reply": "__ANSWER__ Hi, good to hear from you."}])
        self.turn("hello there")
        spoken = self.box.wait_spoken(text="Hi, good to hear from you.")
        self.assertEqual((spoken["source"], spoken["kind"]), ("messenger", "conversation"))
        self.assertEqual(spoken["lifecycle_role"], "conversation")

    def test_messenger_stages_are_recorded_with_the_provider(self):
        """Messenger: the bridge records `messenger_submitted`,
        `messenger_provider_started` and `messenger_first_semantic_output` for
        the command, naming the provider."""
        command = self.turn("what is the weather like")
        for stage in ("messenger_submitted", "messenger_provider_started", "messenger_first_semantic_output"):
            record = self.box.wait_speech_request(
                "record_messenger_stage", stage=stage, command_id=command["relay_command_id"],
            )
            self.assertEqual(record["provider"], self.provider)

    def test_silence_or_failure_speaks_the_degraded_acknowledgement(self):
        """Messenger: a user turn the messenger answers `__SILENT__`, or whose
        provider turn fails, is acknowledged with the degraded text from
        `fallback`, and the command still reaches the mailbox."""
        self.box.script_messenger([
            {"when": "silent please", "reply": "__SILENT__"},
            {"when": "failing please", "fail": True},
        ])
        for text in ("silent please", "failing please"):
            command = self.turn(text)
            spoken = wait_until(
                lambda: [request for request in self.messenger_speech(command)
                         if request["text"] == MESSENGER_DEGRADED_TEXT],
                message=f"the degraded text for {text!r}",
            )[0]
            self.assertEqual(spoken["source"], "fallback")
            self.assertEqual(spoken["kind"], "handoff")
            claimed = self.session.claim()
            self.assertEqual(claimed["source_text"], text)
            self.session.acknowledge(claimed)
            self.box.wait_intent_state(claimed["intent_id"], "acked")

    def test_a_newer_turn_drops_the_messengers_unfinished_answer(self):
        """Messenger: a new user turn while the messenger is still answering an
        older one interrupts it (Codex `turn/interrupt`, Claude by restarting
        the process on the same session); the older answer is never spoken."""
        self.box.script_messenger([{"when": "slow question", "reply": "__HANDOFF__ Slow answer.", "delay": 3}])
        self.turn("slow question")
        self.box.wait_messenger_prompt("user_turn", "slow question")
        self.turn("quick question")
        self.box.wait_spoken(text="Messenger heard: quick question")
        if self.provider == "codex":
            wait_until(lambda: self.box.messenger_records("interrupt"), message="turn/interrupt")
        else:
            relaunched = wait_until(
                lambda: [record for record in self.box.messenger_records("launch") if "--resume" in record["argv"]],
                message="the resumed Claude messenger",
            )[0]
            self.assertTrue(relaunched["argv"][relaunched["argv"].index("--resume") + 1])
        self.assertNeverSpoken("Slow answer.", 3.5)

    def test_the_orchestrators_final_is_spoken_without_asking_the_messenger(self):
        """Messenger: an authoritative reply is spoken word for word; the
        messenger is not asked to rephrase it."""
        command = self.claimed_turn("summarise the incident")
        self.box.say(self.reply_line(command, "The incident was a bad config push."))
        self.box.wait_spoken(text="The incident was a bad config push.")
        self.assertFalse(self.box.messenger_prompts("orchestrator_final"))

    def test_a_final_that_repeats_the_messengers_answer_is_not_spoken_again(self):
        """Messenger: when the messenger already answered a conversational turn,
        a final that adds nothing to that answer is not spoken again; a final
        with new substance is."""
        self.box.script_messenger([
            {"when": "what time is it", "reply": "__ANSWER__ It is noon in Tokyo."},
            {"when": "what day is it", "reply": "__ANSWER__ It is Friday."},
        ])
        first = self.claimed_turn("what time is it in Tokyo")
        self.box.wait_spoken(text="It is noon in Tokyo.")
        self.box.say(self.reply_line(first, "It is noon in Tokyo."))
        self.assertStays(lambda: len(self.box.spoken(text="It is noon in Tokyo.")) == 1)
        second = self.claimed_turn("what day is it today")
        self.box.wait_spoken(text="It is Friday.")
        self.box.say(self.reply_line(second, "It is Friday, and the release ships tonight."))
        self.box.wait_spoken(text="It is Friday, and the release ships tonight.")


class ClaudeSignedOutContract:
    """Claude only: the messenger starts only on a verified subscription."""

    provider = "claude"

    def setUp(self):
        self.start_bridge = False
        super().setUp()
        self.box.script_messenger([], auth={"loggedIn": False})
        self.box.start()

    def test_an_unverified_claude_subscription_keeps_the_messenger_down(self):
        """Messenger: Claude is checked with `claude auth status --json` before
        each start; without a verified subscription it is never started, and
        user turns get the degraded acknowledgement while their commands still
        reach the mailbox."""
        command = self.turn("is anyone there")
        spoken = self.box.wait_spoken(text=MESSENGER_DEGRADED_TEXT, command_id=command["relay_command_id"])
        self.assertEqual(spoken["source"], "fallback")
        launches = self.box.messenger_records("launch")
        self.assertTrue(launches)
        self.assertTrue(all(record["argv"][:2] == ["auth", "status"] for record in launches))
        self.session.wait_pending()


class UnavailableMessengerContract:
    def setUp(self):
        self.start_bridge = False
        super().setUp()
        self.box.config_path.write_text(self.box.config_path.read_text().replace(
            str(self.box.bin / self.provider), str(self.box.bin / "missing" / self.provider)))
        self.box.start()

    def test_a_missing_provider_command_speaks_the_degraded_acknowledgement(self):
        """Messenger: when the messenger's provider command cannot be found each
        turn is acknowledged with the degraded text from `fallback`, the stage
        `messenger_failed` is recorded with the outcome `provider_unavailable`,
        and the command is still delivered."""
        command = self.turn("is anyone there")
        spoken = self.box.wait_spoken(text=MESSENGER_DEGRADED_TEXT, command_id=command["relay_command_id"])
        self.assertEqual((spoken["source"], spoken["kind"]), ("fallback", "handoff"))
        self.box.wait_speech_request("record_messenger_stage", stage="messenger_failed",
                                     outcome="provider_unavailable", command_id=command["relay_command_id"])
        self.session.wait_pending()


class DisabledMessengerContract:
    messenger = False

    def test_a_disabled_messenger_is_silent(self):
        """Messenger: with `messenger_enabled = false` nothing is spoken for a
        user turn: no messenger prompt, no degraded text."""
        command = self.turn("is anyone there")
        self.session.wait_pending()
        self.assertStays(lambda: not self.box.spoken(command_id=command["relay_command_id"]))
        self.assertFalse(self.box.messenger_prompts())


class ClaudeMessenger(MessengerContract, BridgeCase):
    provider = "claude"


class CodexMessenger(MessengerContract, BridgeCase):
    provider = "codex"


class ClaudeSignedOut(ClaudeSignedOutContract, BridgeCase):
    pass


class ClaudeUnavailableMessenger(UnavailableMessengerContract, BridgeCase):
    provider = "claude"


class CodexUnavailableMessenger(UnavailableMessengerContract, BridgeCase):
    provider = "codex"


class ClaudeDisabledMessenger(DisabledMessengerContract, BridgeCase):
    provider = "claude"


class CodexDisabledMessenger(DisabledMessengerContract, BridgeCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
