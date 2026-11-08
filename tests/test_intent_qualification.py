from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))
try:
    import numpy  # noqa: F401
except ModuleNotFoundError:
    # Match the voice-bridge harness only when optional audio dependencies are absent.
    sys.modules.setdefault("numpy", types.SimpleNamespace(asarray=lambda samples: samples, int16=object()))

from command_actions import (
    classify_command, format_command_for_agent, project_work_style, resolve_command_action, session_work_style,
    set_session_work_style, work_style_and_source,
)
from intent_arbitration import ActiveWork, resolve_intent_disposition
from intent_qualification import qualify_intent
from relay_authorization import allowed_mutations_for_metadata
from voice_bridge import _resolve_voice_work_items


class IntentQualificationTests(unittest.TestCase):
    def test_labelled_development_regressions(self):
        corpus = json.loads((ROOT / "tests/fixtures/intent_qualification.json").read_text())
        for case in corpus["cases"]:
            with self.subTest(case=case["id"]):
                action = classify_command(case["text"])
                hint = qualify_intent(case["text"], context=case["context"])
                self.assertEqual(action.kind, case["expected_action_kind"])
                self.assertEqual(hint.bucket, case["expected_bucket"])

    def test_assent_never_invents_authority_from_unverified_context(self):
        for context in ([], [{"role": "assistant", "content": "I could fix login."}]):
            hint = qualify_intent("Yes, do that", context=context)
            self.assertTrue(hint.unresolved)
            self.assertEqual(hint.bucket, "discussion")
            self.assertEqual(hint.reason, "context_required")

    def test_whole_turn_revision_is_preserved_before_split_for_both_providers(self):
        text = "Can you build this? I only want to discuss feasibility, do not implement it."
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                items = _resolve_voice_work_items(
                    text,
                    {"relay_command_seq": 7, "relay_command_id": "revision", "provider": provider},
                    repo_path="/tmp/example", active_work=(ActiveWork("accepted", ("repository",)),),
                )
                self.assertEqual(len(items), 1)
                resolved = items[0]
                self.assertEqual(resolved["item"].source_text, text)
                self.assertEqual(resolved["disposition"].authorization_effect.value, "preserve")
                self.assertEqual(allowed_mutations_for_metadata(resolved["metadata"]), [])
                hint = resolved["metadata"]["intent_qualification"]
                self.assertEqual((hint["command_seq"], hint["command_id"]), (7, "revision"))
                self.assertEqual(hint["bucket"], "discussion")
                self.assertIn(text, resolved["prompt"])
                self.assertIn("may correct this hint", resolved["prompt"])

    def test_later_discussion_revision_overrides_ticket_only_exception(self):
        text = "Create a ticket. Do not implement it. I only want to discuss feasibility."
        items = _resolve_voice_work_items(text, {"relay_command_seq": 8, "relay_command_id": "revised"}, repo_path="/tmp/example")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["action"].kind, "conversation")
        self.assertEqual(allowed_mutations_for_metadata(items[0]["metadata"]), [])

    def test_mixed_scope_is_deferred_without_losing_original_order(self):
        text = "Open Chrome and fix login"
        items = _resolve_voice_work_items(text, {"relay_command_seq": 8, "relay_command_id": "mixed"}, repo_path="/tmp/example")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["item"].source_text, text)
        self.assertTrue(items[0]["metadata"]["intent_qualification"]["mixed"])
        self.assertTrue(items[0]["metadata"]["intent_qualification"]["unresolved"])
        self.assertEqual(allowed_mutations_for_metadata(items[0]["metadata"]), [])

    def test_drafting_permission_does_not_grant_dispatch_or_implementation(self):
        for text in (
            "Create a ticket to fix login; do not dispatch it",
            "Create a ticket for login but do not implement it",
            "Create a ticket for login, backlog only",
        ):
            with self.subTest(text=text):
                items = _resolve_voice_work_items(text, {"relay_command_seq": 9, "relay_command_id": "draft"}, repo_path="/tmp/example")
                self.assertEqual(len(items), 1)
                self.assertEqual(items[0]["metadata"]["intent_qualification"]["bucket"], "task")
                allowed = allowed_mutations_for_metadata(items[0]["metadata"])
                self.assertEqual(len(allowed), 1)
                self.assertEqual(allowed[0]["kind"], "orchestrator_action")
                self.assertIn("create_ticket", allowed[0]["action_kinds"])
                self.assertNotIn("request_worker", allowed[0]["action_kinds"])

    def test_bucket_alone_never_grants_mutation(self):
        for bucket in ("task", "action", "discussion"):
            self.assertEqual(allowed_mutations_for_metadata({
                "action": "conversation", "source_text": "Discuss login",
                "intent_qualification": {"bucket": bucket},
            }), [])

    def test_control_path_is_separate(self):
        for text in ("__TTS_STOP__", "Cancel RR-400"):
            self.assertIsNone(qualify_intent(text).bucket)


class WorkStyleRoutingTests(unittest.TestCase):
    def setUp(self):
        self._saved = {key: os.environ.pop(key, None) for key in (
            "RELAY_WORK_STYLE", "RELAY_SESSION_WORK_STYLE_FILE", "RELAY_SESSION_SCOPE", "RELAY_GENERAL_FILES_ROOT")}
        self._styles_dir = tempfile.TemporaryDirectory()
        self.session_file = Path(self._styles_dir.name) / "session-work-style.json"
        os.environ["RELAY_SESSION_WORK_STYLE_FILE"] = str(self.session_file)

    def tearDown(self):
        for key, value in self._saved.items():
            os.environ.pop(key, None)
            if value is not None:
                os.environ[key] = value
        self._styles_dir.cleanup()

    def test_switching_style_by_voice_is_a_foreground_action_not_a_ticket(self):
        for text, style in (
            ("Switch to direct mode", "direct"),
            ("Okay, can you change to orchestrated mode?", "orchestrated"),
            ("Set the work style to auto", "auto"),
            ("Use direct mode for this project", "direct"),
        ):
            with self.subTest(text=text):
                action = classify_command(text)
                self.assertEqual((action.kind, action.reason), ("direct_action", "set_work_style"))
                self.assertEqual(qualify_intent(text).bucket, "action")
                prompt = format_command_for_agent(action)
                self.assertIn(f"relay-work-style set {style}", prompt)
                self.assertIn("Do not create a ticket", prompt)
        self.assertNotEqual(classify_command("What does direct mode do?").reason, "set_work_style")

    def test_setter_and_cli_write_the_file_the_start_menu_reads(self):
        import subprocess

        def cli(*args):
            return subprocess.run([str(ROOT / "scripts/relay-work-style"), *args],
                                  capture_output=True, text=True, check=True, env=dict(os.environ)).stdout

        with tempfile.TemporaryDirectory() as repo:
            self.assertEqual(session_work_style(), "")
            set_session_work_style("orchestrated")
            self.assertEqual(session_work_style(), "orchestrated")
            self.assertEqual(project_work_style(repo), "orchestrated")
            out = cli("set", "direct", "--repo", repo)
            self.assertIn("direct (makes changes now", out)
            self.assertIn("from the session's choice", out)
            self.assertEqual(json.loads(self.session_file.read_text()), {"work_style": "direct"})
            with self.assertRaises(ValueError):
                set_session_work_style("sometimes")
            self.session_file.unlink()
            self.assertIn("auto (decides per request", cli("show", "--repo", repo))
            self.assertIn("from the default", cli("show", "--repo", repo))
            (Path(repo) / ".relay-runner.toml").write_text('work_style = "orchestrated"\n')
            out = cli("--repo", repo)
            self.assertIn("orchestrated (turns changes into tickets", out)
            self.assertIn("from the project's .relay-runner.toml", out)
            os.environ["RELAY_WORK_STYLE"] = "direct"
            self.assertIn("direct (makes changes now, without tickets), from RELAY_WORK_STYLE", cli("--repo", repo))

    def test_session_choice_beats_the_project_file_and_the_env_beats_both(self):
        with tempfile.TemporaryDirectory() as repo:
            (Path(repo) / ".relay-runner.toml").write_text('work_style = "orchestrated"\n')
            self.assertEqual(work_style_and_source(repo), ("orchestrated", "project"))
            self.session_file.write_text(json.dumps({"work_style": "direct"}))
            self.assertEqual(work_style_and_source(repo), ("direct", "session"))
            self.assertEqual(resolve_command_action("Make the title fade in slower", repo_path=repo).kind, "inline_work")
            os.environ["RELAY_WORK_STYLE"] = "auto"
            self.assertEqual(work_style_and_source(repo), ("auto", "env"))

    def test_invalid_session_choice_is_ignored(self):
        with tempfile.TemporaryDirectory() as repo:
            (Path(repo) / ".relay-runner.toml").write_text('work_style = "orchestrated"\n')
            for saved in ('{"work_style": "sometimes"}', '{"work_style": 1}', '["direct"]', "not json", ""):
                with self.subTest(saved=saved):
                    self.session_file.write_text(saved)
                    self.assertEqual(session_work_style(), "")
                    self.assertEqual(work_style_and_source(repo), ("orchestrated", "project"))
            self.session_file.write_text('{"work_style": "Direct"}')
            self.assertEqual(session_work_style(), "direct")

    def test_labelled_routes_for_every_work_style(self):
        corpus = json.loads((ROOT / "tests/fixtures/work_style_routing.json").read_text())
        with tempfile.TemporaryDirectory() as repo:
            for source, style in ((source, style) for source in ("env", "session")
                                  for style in ("auto", "direct", "orchestrated")):
                if source == "env":
                    os.environ["RELAY_WORK_STYLE"] = style
                else:
                    os.environ.pop("RELAY_WORK_STYLE", None)
                    set_session_work_style(style)
                for case in corpus["cases"]:
                    with self.subTest(source=source, style=style, case=case["id"]):
                        action = resolve_command_action(case["text"], repo_path=repo)
                        hint = qualify_intent(case["text"], action_kind=action.kind, action_reason=action.reason)
                        self.assertEqual([hint.bucket, action.kind], case[style])
                        if hint.bucket == "undecided":
                            self.assertTrue(hint.unresolved)
                            prompt = format_command_for_agent(action)
                            self.assertIn("ask one short question", prompt)
                            self.assertNotIn("action: create_ticket", prompt)

    def test_work_style_file_sets_the_style_and_unknown_values_fall_back_to_auto(self):
        with tempfile.TemporaryDirectory() as repo:
            self.assertEqual(project_work_style(repo), "auto")
            (Path(repo) / ".relay-runner.toml").write_text('# Remotion project\nwork_style = "direct"\n')
            self.assertEqual(project_work_style(repo), "direct")
            action = resolve_command_action("Make the title fade in slower", repo_path=repo)
            self.assertEqual((action.kind, action.reason), ("inline_work", "work_style_direct"))
            self.assertIn("work_style: direct", format_command_for_agent(action))
            (Path(repo) / ".relay-runner.toml").write_text('work_style = "sometimes"\n')
            self.assertEqual(project_work_style(repo), "auto")

    def test_without_a_confirmed_project_change_requests_still_need_a_target(self):
        os.environ["RELAY_WORK_STYLE"] = "direct"
        self.assertEqual(resolve_command_action("Fix the login retry bug in the repo").kind, "needs_project")

    def test_general_session_routes_changes_inline_only_when_the_session_chose_direct(self):
        with tempfile.TemporaryDirectory() as root:
            os.environ.update({"RELAY_SESSION_SCOPE": "general", "RELAY_GENERAL_FILES_ROOT": root})
            text = "Make the title fade in slower"
            # No choice, auto, orchestrated and a project file all keep General's own routing.
            (Path(root) / ".relay-runner.toml").write_text('work_style = "direct"\n')
            for style in (None, "auto", "orchestrated"):
                if style:
                    set_session_work_style(style)
                with self.subTest(style=style):
                    action = resolve_command_action(text, repo_path=root)
                    self.assertEqual((action.kind, action.scope), ("create_ticket", "general"))
            for source in ("session", "env"):
                with self.subTest(source=source):
                    if source == "session":
                        set_session_work_style("direct")
                    else:
                        set_session_work_style("auto")
                        os.environ["RELAY_WORK_STYLE"] = "direct"
                    action = resolve_command_action(text, repo_path=root)
                    self.assertEqual((action.kind, action.reason), ("inline_work", "work_style_direct"))
                    self.assertIsNone(action.repo_path)
                    self.assertIn("This session's work style is direct", format_command_for_agent(action))
                    # Project work still needs a confirmed repository, and tracking wording still wins.
                    self.assertEqual(resolve_command_action("Fix the login retry bug in the repo",
                                                            repo_path=root).kind, "needs_project")
                    self.assertEqual(resolve_command_action("Create a ticket to make the title fade in slower",
                                                            repo_path=root).kind, "create_ticket")

    def test_inline_work_continues_now_unless_other_work_is_active(self):
        free = resolve_intent_disposition(intent_id="a", action_kind="inline_work", action_reason="",
                                          source_text="Fix it inline")
        self.assertEqual(free.route.value, "continue_current")
        busy = resolve_intent_disposition(intent_id="b", action_kind="inline_work", action_reason="",
                                          source_text="Fix it inline",
                                          active_work=(ActiveWork("accepted", ("repository",)),))
        self.assertEqual(busy.route.value, "queue_project_work")

    def test_pending_work_needs_a_clause_start(self):
        self.assertEqual(classify_command("Once those tickets are done, merge them").kind, "control")
        self.assertNotEqual(
            classify_command("I want to improve how we interpret when tickets are done").kind, "control")


if __name__ == "__main__":
    unittest.main()
