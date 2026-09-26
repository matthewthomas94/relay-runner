from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services"))
from laya_qualification import LocalLaya, attach_hint, fallback_reason, qualify_for_bridge


COMMAND = {"relay_command_id": "current-command", "relay_command_seq": 7}


class LayaClientTests(unittest.TestCase):
    def test_default_off_does_not_connect_or_load_runtime(self):
        with patch.dict(os.environ, {}, clear=True), patch("socket.socket") as connect:
            self.assertIsNone(qualify_for_bridge("Open Chrome", COMMAND))
        connect.assert_not_called()
        self.assertNotIn("laya_mlx", sys.modules)
        self.assertNotIn("mlx.core", sys.modules)

    def test_missing_service_is_immediate_fallback(self):
        with patch.dict(os.environ, {"RELAY_LAYA_TEST_MODE": "1", "RELAY_LAYA_SOCKET": "/missing/rr-laya.sock"}):
            result = qualify_for_bridge("Open Chrome", COMMAND)
        self.assertEqual(result["fallback_reason"], "model_service_unavailable")
        self.assertLess(result["elapsed_ms"], 30)

    def exchange(self, text, respond, timeout="100"):
        with tempfile.TemporaryDirectory(prefix="rrlaya-") as folder:
            path = str(Path(folder) / "test.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                server.listen(1)
                def run():
                    connection, _ = server.accept()
                    with connection:
                        request = json.loads(connection.recv(32768))
                        response = respond(request)
                        if response is not None:
                            try:
                                connection.sendall((json.dumps(response) + "\n").encode())
                            except BrokenPipeError:
                                pass
                worker = threading.Thread(target=run, daemon=True)
                worker.start()
                with patch.dict(os.environ, {"RELAY_LAYA_TEST_MODE": "1", "RELAY_LAYA_SOCKET": path, "RELAY_LAYA_TIMEOUT_MS": timeout}):
                    result = qualify_for_bridge(text, COMMAND)
                worker.join(timeout=.5)
                return result

    def test_matching_hint_stays_advisory(self):
        result = self.exchange("Open Chrome", lambda req: {**req, "bucket": "action", "requires_pm": False})
        self.assertEqual(result["bucket"], "action")
        self.assertTrue(result["requires_pm"])
        self.assertTrue(result["advisory_only"])
        self.assertFalse(result["confidence_calibrated"])

    def test_timeout_has_total_deadline(self):
        def delay(_):
            time.sleep(.15)
        result = self.exchange("Open Chrome", delay, timeout="20")
        self.assertEqual(result["fallback_reason"], "timeout")
        self.assertLess(result["elapsed_ms"], 80)

    def test_late_generation_is_dropped(self):
        result = self.exchange("Open Chrome", lambda req: {**req, "bucket": "action", "relay_command_id": "older-command"})
        self.assertEqual(result["fallback_reason"], "stale_command_response")

    def test_negation_cannot_be_overridden_by_high_score(self):
        result = self.exchange("Do NOT cancel my account", lambda req: {**req, "bucket": "action", "confidence": .9998})
        self.assertIsNone(result["bucket"])
        self.assertEqual(result["fallback_reason"], "negation_or_correction_requires_pm")

    def test_invalid_reply_falls_back(self):
        result = self.exchange("Open Chrome", lambda req: ["not", "a", "result"])
        self.assertEqual(result["fallback_reason"], "invalid_model_response")

    def test_guard_families_are_conservative(self):
        for text in ("Do not implement this", "Actually, just research it", "Don't create a ticket", "Stop the work"):
            self.assertEqual(fallback_reason(text, []), "negation_or_correction_requires_pm")
        self.assertEqual(fallback_reason("Yes, do that", []), "unresolved_reference")
        self.assertEqual(fallback_reason("Yes", [{"role": "assistant", "content": "I can send it."}]), "context_reference_requires_pm")
        self.assertEqual(fallback_reason("Open Chrome and then fix the bug", []), "mixed_intent_requires_pm")

    def test_hint_cannot_change_existing_routing_or_authority(self):
        for provider in ("codex", "claude"):
            item = {"metadata": {**COMMAND, "provider": provider, "authorization_relationship": "preserve", "work_disposition": {"route": "continue_current"}}, "prompt": "Original: only discuss this", "action": "conversation", "disposition": "continue_current"}
            original = copy.deepcopy(item)
            attach_hint([item], {**COMMAND, "bucket": "task"})
            self.assertEqual(item["action"], original["action"])
            self.assertEqual(item["disposition"], original["disposition"])
            self.assertEqual(item["metadata"]["authorization_relationship"], "preserve")
            self.assertEqual(item["metadata"]["work_disposition"], {"route": "continue_current"})
            self.assertTrue(item["prompt"].startswith(original["prompt"]))
            self.assertIn("cannot authorize", item["prompt"])

    def test_attach_drops_stale_hint(self):
        item = {"metadata": dict(COMMAND), "prompt": "Original"}
        attach_hint([item], {**COMMAND, "relay_command_seq": 6, "bucket": "task"})
        self.assertEqual(item, {"metadata": COMMAND, "prompt": "Original"})


class ModelBoundaryTests(unittest.TestCase):
    def fake_model(self, budget=500):
        # No neural result is asserted here: this verifies budgeting and guards.
        model = LocalLaya.__new__(LocalLaya)
        class Tokenizer:
            mask_token = "[MASK]"
            def __call__(self, text, **kwargs):
                return {"input_ids": text.split()}
        class Agent:
            tok = Tokenizer()
            calls = 0
            def predict(self, state, questions):
                self.calls += 1
                self.state = state
                return {"answers": {"intent": {"choice": "action", "probabilities": {"action": .9998, "task": .0001, "discussion": .0001}, "confidence": .9998}}, "usage": {"input_tokens": 20}}
        class MX:
            def synchronize(self):
                pass
        model.agent = Agent()
        model.mx = MX()
        model.state_budget = budget
        model.identity = {"test_double": True}
        return model

    def test_context_overflow_abstains_without_truncating(self):
        model = self.fake_model(budget=6)
        output = model.qualify({**COMMAND, "text": "Send it", "context": [{"role": "user", "content": "We are discussing a draft and have not approved sending"}]})
        self.assertEqual(output["fallback_reason"], "context_would_truncate")
        self.assertEqual(model.agent.calls, 0)

    def test_raw_error_remains_visible_under_guard(self):
        model = self.fake_model()
        output = model.qualify({**COMMAND, "text": "Do not send an email", "context": []})
        self.assertEqual(output["raw_bucket"], "action")
        self.assertIsNone(output["bucket"])
        self.assertEqual(output["confidence"], .9998)

    def test_ordered_context_is_present_and_reference_stays_with_pm(self):
        model = self.fake_model()
        context = [{"role": "user", "content": "Discuss a draft"}, {"role": "assistant", "content": "Send or review?"}]
        output = model.qualify({**COMMAND, "text": "Yes", "context": context})
        self.assertEqual(model.agent.state, "user: Discuss a draft\nassistant: Send or review?\ncurrent user: Yes")
        self.assertIsNone(output["bucket"])


if __name__ == "__main__":
    unittest.main()
