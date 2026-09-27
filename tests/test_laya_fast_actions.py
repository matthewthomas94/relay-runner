from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services"))
from command_actions import classify_command
from intent_qualification import qualify_intent
from laya_fast_actions import execute_fast_action, parse_fast_action, try_fast_action


COMMAND = {"relay_command_id": "voice-7", "relay_command_seq": 7}


def resolved(kind="direct_action", bucket="action", lifecycle="recognized", route="continue_current", item_disposition="accepted"):
    return [{
        "item": SimpleNamespace(lifecycle_state=lifecycle, disposition=item_disposition),
        "action": SimpleNamespace(kind=kind),
        "disposition": SimpleNamespace(
            route=SimpleNamespace(value=route),
            cancellation_scope=SimpleNamespace(value="none"),
        ),
        "metadata": {**COMMAND, "intent_qualification": {"bucket": bucket}},
    }]


class ParsingTests(unittest.TestCase):
    def test_exact_local_operations(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder)
            cases = {
                "Open Calculator": ("open_app", "Calculator"),
                "Bring up Google Chrome": ("open_app", "Google Chrome"),
                "Open https://example.com/path?q=1": ("open_url", "https://example.com/path?q=1"),
                "Open the project folder": ("open_path", str(repo)),
                f"Reveal {folder} in Finder": ("reveal_path", folder),
                "Press Command S": ("key", "cmd+s"),
                "Click at 123, 456": ("click", {"x": 123, "y": 456}),
                "Scroll down 3 lines at (123, 456)": ("scroll", {"x": 123, "y": 456, "dy": -3}),
                'Type "hello world" into the focused field': ("type", "hello world"),
            }
            for utterance, expected in cases.items():
                with self.subTest(utterance=utterance):
                    action = parse_fast_action(utterance, repo_path=repo)
                    self.assertIsNotNone(action)
                    self.assertEqual((action.kind, action.target), expected)

    def test_discussion_mixed_and_unresolved_actions_stay_with_pm(self):
        for utterance in (
            "What would happen if we opened Calculator?",
            "Open Calculator and then send an email",
            "Let's open Calculator after we discuss it",
            "Don't open Calculator",
            "Click the Save button",
            "Send an email to Alex",
            "Start the dev server",
            "Open ftp://example.com",
        ):
            with self.subTest(utterance=utterance):
                self.assertIsNone(parse_fast_action(utterance, repo_path=Path.cwd()))


class RoutingTests(unittest.TestCase):
    def test_shared_framework_keeps_task_and_discussion_out_of_fast_path(self):
        with patch.dict(os.environ, {"RELAY_LAYA_FAST_ACTIONS": "1"}), patch(
            "laya_fast_actions.execute_fast_action"
        ) as execute:
            for text, expected in (
                ("Open Calculator", "action"),
                ("I want to talk through opening Calculator", "discussion"),
                ("Create a ticket to fix Calculator", "task"),
            ):
                with self.subTest(text=text):
                    action = classify_command(text)
                    bucket = qualify_intent(
                        text, action_kind=action.kind, action_reason=action.reason,
                    ).bucket
                    self.assertEqual(bucket, expected)
                    items = resolved(kind=action.kind, bucket=bucket)
                    outcome = try_fast_action(
                        text, repo_path=Path.cwd(), resolved_items=items,
                        hint={**COMMAND, "bucket": "action"}, current_command=lambda: True,
                    )
                    self.assertEqual(outcome is not None, expected == "action")
            execute.assert_called_once()

    def test_laya_and_framework_must_agree_on_one_current_action(self):
        hint = {**COMMAND, "bucket": "action"}
        with patch.dict(os.environ, {"RELAY_LAYA_FAST_ACTIONS": "1"}), patch(
            "laya_fast_actions.execute_fast_action"
        ) as execute:
            execute.return_value = SimpleNamespace(text="Opened Calculator.", confirmed=True, kind="open_app")
            output = try_fast_action(
                "Open Calculator", repo_path=Path.cwd(), resolved_items=resolved(),
                hint=hint, current_command=lambda: True,
            )
            self.assertEqual(output.text, "Opened Calculator.")
            execute.assert_called_once()

            blocked = [
                (resolved(kind="conversation"), hint),
                (resolved(bucket="discussion"), hint),
                (resolved(lifecycle="cancelled"), hint),
                (resolved(item_disposition="deferred"), hint),
                (resolved(route="clarify_priority"), hint),
                (resolved(), {**hint, "bucket": "discussion"}),
                (resolved(), {**hint, "fallback_reason": "negation_or_correction_requires_pm"}),
                (resolved(), {**hint, "relay_command_id": "older"}),
                (resolved() * 2, hint),
            ]
            for items, model_hint in blocked:
                with self.subTest(items=items, model_hint=model_hint):
                    self.assertIsNone(try_fast_action(
                        "Open Calculator", repo_path=Path.cwd(), resolved_items=items,
                        hint=model_hint, current_command=lambda: True,
                    ))
            self.assertIsNone(try_fast_action(
                "Open Calculator", repo_path=Path.cwd(), resolved_items=resolved(),
                hint=hint, current_command=lambda: False,
            ))
            execute.assert_called_once()

    def test_default_off_never_executes(self):
        with patch.dict(os.environ, {"RELAY_LAYA_FAST_ACTIONS": "0"}), patch(
            "laya_fast_actions.execute_fast_action"
        ) as execute:
            self.assertIsNone(try_fast_action(
                "Open Calculator", repo_path=Path.cwd(), resolved_items=resolved(),
                hint={**COMMAND, "bucket": "action"}, current_command=lambda: True,
            ))
            execute.assert_not_called()


class ExecutionTests(unittest.TestCase):
    def test_app_open_uses_argument_vector_without_shell(self):
        action = parse_fast_action("Open Google Chrome", repo_path=Path.cwd())
        with patch("laya_fast_actions.subprocess.run") as run:
            run.return_value.returncode = 0
            result = execute_fast_action(action)
        self.assertTrue(result.confirmed)
        self.assertEqual(run.call_args.args[0], ["/usr/bin/open", "-a", "Google Chrome"])
        self.assertNotIn("shell", run.call_args.kwargs)

    def test_hosted_key_uses_relay_actions(self):
        action = parse_fast_action("Press Escape", repo_path=Path.cwd())
        with patch("laya_fast_actions._relay_action", return_value=True) as relay:
            result = execute_fast_action(action)
        self.assertTrue(result.confirmed)
        relay.assert_called_once_with("key", {"combo": "escape"})

    def test_uncertain_submission_does_not_claim_success(self):
        action = parse_fast_action("Open Calculator", repo_path=Path.cwd())
        with patch("laya_fast_actions.subprocess.run", side_effect=TimeoutError):
            result = execute_fast_action(action)
        self.assertFalse(result.confirmed)
        self.assertIn("could not confirm", result.text)


if __name__ == "__main__":
    unittest.main()
