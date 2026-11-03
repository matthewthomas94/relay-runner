"""RR-460: a late PM final replaces the spoken missing-reply fallback."""

from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "services"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.modules.setdefault("numpy", types.SimpleNamespace(asarray=lambda s: s, int16=object()))

import voice_bridge  # noqa: E402
from speech_coordinator import SpeechCoordinator  # noqa: E402
from test_speech_coordinator import FakeWorker  # noqa: E402


class FakeMessenger:
    def __init__(self):
        self.finals: list[dict] = []

    def submit_final(self, payload: dict) -> bool:
        self.finals.append(dict(payload))
        return True


class FakeTTSWorker:
    def __init__(self):
        self.input_queue = queue.Queue()


def wait_until(predicate, timeout: float = 2.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


class LateFinalTestCase(unittest.TestCase):
    def setUp(self):
        voice_bridge._reset_foreground_reply_delivery_for_tests()
        self.addCleanup(voice_bridge._reset_foreground_reply_delivery_for_tests)
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = temp.name
        self.state_path = os.path.join(self.root, "voice_command_state.json")
        self.turns_path = os.path.join(self.root, "voice_provider_turns.json")
        self.speech_log = Path(self.root) / "speech-events.jsonl"
        self.fallback_events: list[tuple[str, str | None]] = []
        patcher = mock.patch.object(
            voice_bridge,
            "_log_foreground_reply_fallback_event",
            side_effect=lambda event, **fields: self.fallback_events.append(
                (event, fields.get("reason"))
            ),
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        poll = mock.patch.object(voice_bridge, "PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS", 0.01)
        poll.start()
        self.addCleanup(poll.stop)
        continuity = mock.patch.object(voice_bridge, "_post_continuity_event")
        continuity.start()
        self.addCleanup(continuity.stop)

    def command(self, text: str = "dispatch the long work") -> dict:
        return voice_bridge._begin_relay_command(
            text,
            state_path=self.state_path,
            event_log_path=None,
        )

    def write_turn(self, command: dict, state: str) -> None:
        Path(self.turns_path).write_text(json.dumps({"records": [{
            **command,
            "session_id": "provider-session",
            "state": state,
            "updated_at": time.time(),
        }]}))

    def schedule(self, command: dict, tts_worker, messenger, **kwargs):
        return voice_bridge._schedule_foreground_reply_fallback(
            relay_command=command,
            tts_worker=tts_worker,
            messenger=messenger,
            state_path=self.state_path,
            turns_path=self.turns_path,
            delay_seconds=0,
            **kwargs,
        )

    def coordinator(self) -> tuple[FakeWorker, SpeechCoordinator]:
        worker = FakeWorker()
        return worker, SpeechCoordinator(
            worker,
            is_current=lambda seq, command_id: True,
            event_log_path=self.speech_log,
        )

    def speech_events(self, name: str | None = None) -> list[dict]:
        if not self.speech_log.exists():
            return []
        records = [json.loads(line) for line in self.speech_log.read_text().splitlines()]
        return [record for record in records if name is None or record["event"] == name]


class FallbackDeferralTests(LateFinalTestCase):
    def assert_defers_then_speaks(self, command, messenger, thread, finish) -> None:
        self.assertTrue(wait_until(
            lambda: ("deferred", "provider_turn_active") in self.fallback_events
        ))
        self.assertEqual(messenger.finals, [])
        self.assertNotIn("source_not_terminal", {reason for _, reason in self.fallback_events})
        finish()
        thread.join(timeout=2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(len(messenger.finals), 1)
        self.assertIn("did not send a spoken final reply", messenger.finals[0]["text"])
        self.assertEqual(messenger.finals[0]["speech_source"], "fallback")

    def test_active_ledger_turn_defers_until_it_is_terminal(self):
        command = self.command()
        self.write_turn(command, "active")
        messenger = FakeMessenger()
        thread = self.schedule(command, FakeTTSWorker(), messenger, ceiling_seconds=60)

        self.assert_defers_then_speaks(
            command, messenger, thread, lambda: self.write_turn(command, "empty")
        )
        self.assertIn(("eligible", "all_siblings_terminal_empty"), self.fallback_events)

    def test_active_broker_turn_defers_and_uses_its_own_effect(self):
        command = self.command()
        projection = os.path.join(self.root, "voice_provider_turns_v2.json")
        Path(projection).write_text(json.dumps({"records": [{**command, "state": "active"}]}))
        broker = mock.Mock(projection_path=projection)
        messenger = FakeMessenger()
        thread = self.schedule(
            command, FakeTTSWorker(), messenger, ceiling_seconds=60, provider_turn_broker=broker
        )

        self.assert_defers_then_speaks(
            command,
            messenger,
            thread,
            lambda: Path(projection).write_text(json.dumps({"records": [{**command, "state": "empty"}]})),
        )
        self.assertEqual(
            broker.reserve_effect.call_args.kwargs["effect_kind"], "missing_reply_fallback"
        )

    def test_recent_pm_trace_defers_until_it_goes_quiet(self):
        command = self.command()
        messenger = FakeMessenger()
        with mock.patch.object(voice_bridge, "FOREGROUND_REPLY_TRACE_ACTIVE_SECONDS", 0.2):
            voice_bridge._handle_orchestration_trace_control(
                json.dumps({"kind": "reasoning-summary", "message": "Working.", "relay_command": command}),
                messenger=None,
                state_path=self.state_path,
                notify_state=lambda *args, **kwargs: None,
            )
            thread = self.schedule(command, FakeTTSWorker(), messenger, ceiling_seconds=60)
            self.assert_defers_then_speaks(command, messenger, thread, lambda: None)

    def test_hard_ceiling_speaks_even_while_the_turn_is_active(self):
        command = self.command()
        self.write_turn(command, "active")
        messenger = FakeMessenger()

        thread = self.schedule(command, FakeTTSWorker(), messenger, ceiling_seconds=0.1)
        thread.join(timeout=2)

        self.assertEqual(len(messenger.finals), 1)
        self.assertIn(("deferred", "provider_turn_active"), self.fallback_events)
        self.assertIn(("eligible", "hard_ceiling:provider_turn_active"), self.fallback_events)


class LateFinalDeliveryTests(LateFinalTestCase):
    def deliver_fallback(self, command, tts_worker, messenger) -> None:
        thread = self.schedule(command, tts_worker, messenger)
        thread.join(timeout=2)
        self.assertIn(("emitted", "all_siblings_terminal_empty"), self.fallback_events)

    def test_late_completion_final_reaches_the_messenger_for_both_providers(self):
        for provider in ("claude", "codex"):
            with self.subTest(provider=provider):
                voice_bridge._reset_foreground_reply_delivery_for_tests()
                command = self.command()
                messenger = FakeMessenger()
                self.deliver_fallback(command, FakeTTSWorker(), messenger)

                self.assertTrue(voice_bridge._handle_provider_completion_control(
                    json.dumps({**command, "provider": provider, "text": "The real result."}),
                    tts_worker=FakeTTSWorker(),
                    messenger=messenger,
                    state_path=self.state_path,
                ))
                # A second real final is still deduplicated.
                self.assertTrue(voice_bridge._handle_orchestrator_reply_control(
                    json.dumps({**command, "text": "Again."}),
                    tts_worker=FakeTTSWorker(),
                    messenger=messenger,
                    state_path=self.state_path,
                ))

                self.assertEqual(
                    [(final["text"], final.get("speech_source")) for final in messenger.finals[1:]],
                    [("The real result.", "completion")],
                )

    def test_fallback_is_not_spoken_after_a_real_final(self):
        command = self.command()
        messenger = FakeMessenger()
        self.assertTrue(voice_bridge._handle_orchestrator_reply_control(
            json.dumps({**command, "text": "The real result."}),
            tts_worker=FakeTTSWorker(),
            messenger=messenger,
            state_path=self.state_path,
        ))

        self.schedule(command, FakeTTSWorker(), messenger).join(timeout=2)

        self.assertEqual([final["text"] for final in messenger.finals], ["The real result."])
        self.assertIn(("cancelled", "reply_delivered"), self.fallback_events)

    def test_replayed_long_turn_speaks_the_late_final_without_a_messenger(self):
        worker, coordinator = self.coordinator()
        command = self.command()
        self.deliver_fallback(command, coordinator, None)
        fallback = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", fallback)

        self.assertTrue(voice_bridge._handle_provider_completion_control(
            json.dumps({**command, "provider": "claude", "text": "The real result."}),
            tts_worker=coordinator,
            messenger=None,
            state_path=self.state_path,
        ))

        final = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual((final["source"], final["kind"]), ("completion", "final"))
        self.assertEqual(final["dedup_key"], "outcome:%d:%s" % (
            command["relay_command_seq"], command["relay_command_id"],
        ))
        worker.observer("cancelled", fallback)
        self.assertTrue(worker.eligibility(final))
        events = [
            (record["event"], record["source"], record["kind"])
            for record in self.speech_events()
            if record["event"] in {"accepted", "replaced", "deduplicated"}
        ]
        self.assertEqual(events, [
            ("accepted", "fallback", "fallback"),
            ("replaced", "fallback", "fallback"),
            ("accepted", "completion", "final"),
        ])
        self.assertEqual(self.speech_events("missing_outcome"), [])


class MissingOutcomeTests(LateFinalTestCase):
    def test_turn_without_hook_or_outcome_logs_one_missing_outcome(self):
        _, coordinator = self.coordinator()
        command = self.command()
        voice_bridge._watch_command_outcome(command)
        voice_bridge._note_daemon_fetch_failure(TimeoutError("timed out"))
        self.write_turn(command, "active")

        voice_bridge._sweep_outcome_watches(coordinator, turns_path=self.turns_path)
        self.assertEqual(self.speech_events("missing_outcome"), [])

        self.write_turn(command, "empty")
        voice_bridge._sweep_outcome_watches(coordinator, turns_path=self.turns_path)
        voice_bridge._sweep_outcome_watches(coordinator, turns_path=self.turns_path)

        missing = self.speech_events("missing_outcome")
        self.assertEqual(len(missing), 1)
        self.assertEqual(
            (missing[0]["relay_command_seq"], missing[0]["relay_command_id"], missing[0]["reason"]),
            (command["relay_command_seq"], command["relay_command_id"], "hook_not_received"),
        )
        self.assertEqual(missing[0]["signals"], [
            "daemon_fetch_timed_out", "hook_not_received", "provider_turn_terminal",
        ])

    def test_rejected_reply_is_named_when_the_turn_ends_silently(self):
        _, coordinator = self.coordinator()
        command = self.command()
        voice_bridge._watch_command_outcome(command)
        self.command("a newer request")  # The reply's command is now stale.
        self.assertFalse(voice_bridge._handle_orchestrator_reply_control(
            json.dumps({**command, "text": "Too late."}),
            tts_worker=coordinator,
            messenger=None,
            state_path=self.state_path,
        ))
        self.write_turn(command, "completed_final")

        voice_bridge._sweep_outcome_watches(coordinator, turns_path=self.turns_path)

        missing = self.speech_events("missing_outcome")
        self.assertEqual([record["reason"] for record in missing], ["reply_helper_rejected"])

    def test_hook_with_superseded_fallback_logs_once_and_delivered_turn_logs_nothing(self):
        _, coordinator = self.coordinator()
        silent = self.command("first")
        voice_bridge._watch_command_outcome(silent)
        answered = self.command("second")
        voice_bridge._watch_command_outcome(answered)

        # The first command's hook arrives empty after it was superseded.
        self.assertFalse(voice_bridge._handle_provider_completion_control(
            json.dumps({**silent, "provider": "codex"}),
            tts_worker=coordinator,
            messenger=None,
            state_path=self.state_path,
            fallback_delay_seconds=0,
        ))
        self.assertTrue(voice_bridge._handle_provider_completion_control(
            json.dumps({**answered, "provider": "claude", "text": "Done."}),
            tts_worker=coordinator,
            messenger=None,
            state_path=self.state_path,
        ))
        self.write_turn(answered, "completed_final")
        voice_bridge._sweep_outcome_watches(coordinator, turns_path=self.turns_path)

        missing = self.speech_events("missing_outcome")
        self.assertEqual(
            [(record["relay_command_id"], record["reason"]) for record in missing],
            [(silent["relay_command_id"], "completion_superseded")],
        )


if __name__ == "__main__":
    unittest.main()
