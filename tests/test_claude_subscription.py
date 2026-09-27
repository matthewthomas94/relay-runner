from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

import claude_subscription  # noqa: E402
from claude_subscription import check, evaluate  # noqa: E402

SUBSCRIPTION = {"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty",
                "email": "person@example.com", "subscriptionType": "max"}
SECRET = "sk-ant-api03-SECRET-VALUE"


class EvaluateTests(unittest.TestCase):
    def assertBlocked(self, readiness, reason, state="blocked"):
        self.assertFalse(readiness.ready)
        self.assertEqual((readiness.state, readiness.reason), (state, reason))
        self.assertNotIn(SECRET, readiness.message)
        self.assertIn("subscription", readiness.message)

    def test_subscription_login_is_verified(self):
        for plan in ("pro", "max", "team", "enterprise"):
            status = {**SUBSCRIPTION, "subscriptionType": plan}
            self.assertTrue(evaluate({}, [], status).ready, plan)

    def test_environment_routes_block_even_when_status_reports_a_subscription(self):
        # `claude auth status` keeps reporting claude.ai for these routes.
        for name, value in (
            ("ANTHROPIC_API_KEY", SECRET),
            ("ANTHROPIC_AUTH_TOKEN", SECRET),
            ("CLAUDE_CODE_USE_BEDROCK", "1"),
            ("CLAUDE_CODE_USE_VERTEX", "true"),
            ("CLAUDE_CODE_USE_FOUNDRY", "1"),
            ("AWS_BEARER_TOKEN_BEDROCK", SECRET),
            ("ANTHROPIC_PROFILE", "work"),
            ("ANTHROPIC_FEDERATION_RULE_ID", "fdrl_123"),
            ("ANTHROPIC_BASE_URL", "https://gateway.example.com"),
        ):
            readiness = evaluate({name: value}, [], SUBSCRIPTION)
            self.assertBlocked(readiness, "metered_environment")
            self.assertIn(name, readiness.message)

    def test_disabled_cloud_flags_and_first_party_base_url_do_not_block(self):
        environment = {"CLAUDE_CODE_USE_BEDROCK": "0", "CLAUDE_CODE_USE_VERTEX": "false",
                       "ANTHROPIC_API_KEY": "", "ANTHROPIC_BASE_URL": "https://api.anthropic.com"}
        self.assertTrue(evaluate(environment, [], SUBSCRIPTION).ready)

    def test_settings_env_and_api_key_helper_block(self):
        cases = (
            ({"env": {"ANTHROPIC_API_KEY": SECRET}}, "metered_settings"),
            ({"env": {"CLAUDE_CODE_USE_VERTEX": "1"}}, "metered_settings"),
            ({"apiKeyHelper": "/usr/local/bin/print-key"}, "api_key_helper"),
            ({"forceLoginMethod": "console"}, "console_login"),
        )
        for document, reason in cases:
            readiness = evaluate({}, [("/work/.claude/settings.local.json", document)], SUBSCRIPTION)
            self.assertBlocked(readiness, reason)
            self.assertIn("/work/.claude/settings.local.json", readiness.message)
            self.assertNotIn("print-key", readiness.message)

    def test_status_reported_api_key_and_cloud_routes_block(self):
        for status, reason in (
            ({**SUBSCRIPTION, "apiKeySource": "ANTHROPIC_API_KEY"}, "api_key"),
            ({**SUBSCRIPTION, "apiKeySource": "/login managed key", "subscriptionType": None}, "api_key"),
            ({"loggedIn": True, "authMethod": "api_key_helper", "apiProvider": "firstParty"}, "api_key"),
            ({"loggedIn": True, "authMethod": "third_party", "apiProvider": "bedrock"}, "third_party"),
            ({"loggedIn": True, "authMethod": "third_party", "apiProvider": "vertex"}, "third_party"),
        ):
            self.assertBlocked(evaluate({}, [], status), reason)

    def test_console_account_without_a_plan_is_blocked(self):
        status = {**SUBSCRIPTION, "subscriptionType": None}
        self.assertBlocked(evaluate({}, [], status), "no_subscription")

    def test_missing_expired_or_ambiguous_status_fails_closed(self):
        self.assertBlocked(evaluate({}, [], None), "status_unavailable", "unverified")
        self.assertBlocked(evaluate({}, [], {"loggedIn": False, "authMethod": "none"}),
                           "not_logged_in", "unverified")
        self.assertBlocked(evaluate({}, [], {"loggedIn": True, "authMethod": "future", "apiProvider": "firstParty"}),
                           "unknown_route", "unverified")

    def test_oauth_token_is_not_an_api_key_and_needs_a_reported_plan(self):
        # Claude Code 2.1.239 reports no plan for CLAUDE_CODE_OAUTH_TOKEN.
        token = {"loggedIn": True, "authMethod": "oauth_token", "apiProvider": "firstParty"}
        readiness = evaluate({"CLAUDE_CODE_OAUTH_TOKEN": SECRET}, [], token)
        self.assertBlocked(readiness, "oauth_token_unverified", "unverified")
        self.assertNotIn("API key", readiness.message)
        verified = evaluate({"CLAUDE_CODE_OAUTH_TOKEN": SECRET}, [], {**token, "subscriptionType": "max"})
        self.assertTrue(verified.ready)

    def test_sign_in_guidance_never_suggests_an_api_key(self):
        for readiness in (evaluate({}, [], None), evaluate({}, [], {**SUBSCRIPTION, "subscriptionType": None})):
            self.assertIn("claude auth login", readiness.message)
            self.assertNotIn("ANTHROPIC_API_KEY", readiness.message)


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        (self.home / ".claude").mkdir()
        self.project = self.home / "project"
        (self.project / ".claude").mkdir(parents=True)
        self.calls = []

    def tearDown(self):
        self.temp.cleanup()

    def run_status(self, status):
        def run(args, **kwargs):
            self.calls.append((args, kwargs))
            return subprocess.CompletedProcess(args, 0, stdout=json.dumps(status), stderr="")
        return run

    def check(self, environment, status=SUBSCRIPTION):
        environment = {"HOME": str(self.home), **environment}
        return evaluate(
            environment,
            claude_subscription.settings_documents(
                str(self.project), environment, managed=self.home / "managed-settings.json"),
            claude_subscription.auth_status(["/bin/claude"], environment, str(self.project),
                                            run=self.run_status(status)),
        )

    def test_status_runs_with_the_launch_environment_and_cwd(self):
        readiness = check(["/bin/claude"], cwd=str(self.project),
                          environment={"HOME": str(self.home), "CLAUDE_CONFIG_DIR": str(self.home / ".claude")},
                          run=self.run_status(SUBSCRIPTION))
        self.assertTrue(readiness.ready)
        args, kwargs = self.calls[0]
        self.assertEqual(args, ["/bin/claude", "auth", "status", "--json"])
        self.assertEqual(kwargs["cwd"], str(self.project))
        self.assertEqual(kwargs["env"]["CLAUDE_CONFIG_DIR"], str(self.home / ".claude"))

    def test_user_project_local_and_managed_settings_env_are_read(self):
        for path in (self.home / ".claude" / "settings.json",
                     self.project / ".claude" / "settings.json",
                     self.project / ".claude" / "settings.local.json",
                     self.home / "managed-settings.json"):
            path.write_text(json.dumps({"env": {"ANTHROPIC_AUTH_TOKEN": SECRET}}))
            readiness = self.check({})
            self.assertEqual(readiness.reason, "metered_settings", path)
            self.assertNotIn(SECRET, readiness.message)
            path.unlink()
        self.assertTrue(self.check({}).ready)

    def test_claude_config_dir_selects_the_user_settings(self):
        custom = self.home / "custom-claude"
        custom.mkdir()
        (custom / "settings.json").write_text(json.dumps({"apiKeyHelper": "print-key"}))
        self.assertTrue(self.check({}).ready)
        self.assertEqual(self.check({"CLAUDE_CONFIG_DIR": str(custom)}).reason, "api_key_helper")

    def test_active_federation_profile_blocks_but_a_user_oauth_profile_does_not(self):
        configs = self.home / ".config" / "anthropic" / "configs"
        configs.mkdir(parents=True)
        (configs / "default.json").write_text(json.dumps({"authentication": {"type": "user_oauth"}}))
        environment = {"HOME": str(self.home)}
        self.assertEqual(claude_subscription.active_profile_type(environment), "user_oauth")
        self.assertTrue(evaluate(environment, [], SUBSCRIPTION, "user_oauth").ready)
        (configs / "ci.json").write_text(json.dumps({"authentication": {"type": "oidc_federation"}}))
        (configs.parent / "active_config").write_text("ci\n")
        self.assertEqual(claude_subscription.active_profile_type(environment), "oidc_federation")
        readiness = evaluate(environment, [], SUBSCRIPTION, "oidc_federation")
        self.assertEqual((readiness.state, readiness.reason), ("blocked", "federation_profile"))

    def test_unreadable_status_fails_closed(self):
        def broken(args, **kwargs):
            return subprocess.CompletedProcess(args, 1, stdout="not json", stderr="")

        def missing(args, **kwargs):
            raise FileNotFoundError(args[0])

        for run in (broken, missing):
            readiness = check(["/bin/claude"], cwd=str(self.project),
                              environment={"HOME": str(self.home)}, run=run)
            self.assertEqual(readiness.state, "unverified")


if __name__ == "__main__":
    unittest.main()
