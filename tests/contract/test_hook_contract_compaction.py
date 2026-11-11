"""Compaction contract: PreCompact, PostCompact and the context diagnostics.

Every lifecycle event appends one line to the compaction events file. The
active context size comes from the provider's own transcript, which the two
providers write in different shapes.
"""

from __future__ import annotations

import json
import os
import unittest

from hook_contract_support import ContractCase

OTHER_SESSION = "11111111-2222-4333-8444-555555555555"
THRESHOLD = 150000
TAIL_BYTES = 2 * 1024 * 1024


def claude_usage(input_tokens, cache_creation=0, cache_read=0, **record) -> dict:
    usage = {
        "input_tokens": input_tokens,
        "cache_creation_input_tokens": cache_creation,
        "cache_read_input_tokens": cache_read,
        "output_tokens": 4000,
    }
    return dict({"type": "assistant", "isSidechain": False, "message": {"role": "assistant", "usage": usage}}, **record)


def claude_compact_boundary(post_tokens=None) -> dict:
    metadata = {"trigger": "auto", "preTokens": 160000}
    if post_tokens is not None:
        metadata["postTokens"] = post_tokens
    return {"type": "system", "subtype": "compact_boundary", "compactMetadata": metadata}


def codex_token_count(last_total, *, info=True) -> dict:
    payload = {"type": "token_count", "info": None}
    if info:
        payload["info"] = {
            "total_token_usage": {"total_tokens": last_total * 3 + 1},
            "last_token_usage": {"input_tokens": last_total - 1, "total_tokens": last_total},
            "model_context_window": 272000,
        }
    return {"timestamp": "2026-01-01T00:00:00.000Z", "type": "event_msg", "payload": payload}


class CompactionCase(ContractCase):
    def run_event(self, event: str, *, env=None, **fields):
        result = self.box.hook(self.box.payload(event, **fields), env=env)
        self.assertQuietSuccess(result)
        return result

    def events(self, path=None) -> list:
        """Recorded events, without the timestamps this checks."""
        path = path or self.box.compaction_events_path
        events = self.box.jsonl(path)
        if events:
            raw = path.read_text()
            canonical = "".join(
                json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n" for event in events
            )
            self.assertEqual(raw, canonical)
            self.assertEqual(self.box.mode(path), 0o600)
        for event in events:
            self.assertRegex(event.pop("timestamp"), r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        return events

    def event(self, stage: str, outcome: str, **fields) -> dict:
        event = {
            "stage": stage,
            "outcome": outcome,
            "provider": self.provider,
            "session_id": self.box.NATIVE_SESSION_ID,
            "native_active_context_tokens": None,
            "threshold_tokens": THRESHOLD,
            "threshold_state": "unknown",
            "idle_boundary": "provider_native",
            "attempt": None,
            "trigger": None,
            "confirmation": False,
            "failure_reason": None,
        }
        event.update(fields)
        return event

    def observed(self, tokens, state: str) -> dict:
        return {"native_active_context_tokens": tokens, "threshold_state": state}

    def assertTokens(self, expected) -> None:
        """The context size the next event reads from the transcript."""
        before = len(self.events())
        self.run_event("PreCompact", trigger="auto")
        self.assertEqual(self.events()[before]["native_active_context_tokens"], expected)


class CompactionContract:
    """Cases every provider must satisfy. `tokens(n)` writes its transcript."""

    def test_pre_compact_records_a_started_attempt(self):
        box = self.box
        self.tokens(151000)
        result = self.run_event("PreCompact", trigger="auto", custom_instructions="keep the PRIVATE plan")
        self.assertNotIn("PRIVATE", result.stderr)
        self.assertEqual(self.events(), [
            self.event("compaction_attempt", "started", attempt=1, trigger="auto",
                       **self.observed(151000, "above")),
        ])
        self.assertNotIn("PRIVATE", box.compaction_events_path.read_text())
        self.assertEqual(box.fifo_lines(), [])
        self.assertEqual(box.ledger_records(), [])
        self.assertEqual(box.rows("provider_turns"), [])
        self.assertFalse(box.session_events_path.exists())

    def test_each_pre_compact_advances_the_attempt_of_its_session(self):
        self.run_event("PreCompact", trigger="auto")
        self.run_event("PreCompact", trigger="manual")
        self.run_event("PreCompact", trigger="auto", session=OTHER_SESSION)
        self.run_event("PostCompact", trigger="manual")
        self.assertEqual(
            [(e["stage"], e["session_id"], e["attempt"], e["trigger"]) for e in self.events()],
            [
                ("compaction_attempt", self.box.NATIVE_SESSION_ID, 1, "auto"),
                ("compaction_attempt", self.box.NATIVE_SESSION_ID, 2, "manual"),
                ("compaction_attempt", OTHER_SESSION, 1, "auto"),
                ("compaction_unconfirmed", self.box.NATIVE_SESSION_ID, 2, "manual"),
            ],
        )

    def test_post_compact_below_the_threshold_confirms_the_attempt(self):
        self.tokens(151000)
        self.run_event("PreCompact", trigger="auto")
        self.tokens(42000)
        result = self.run_event("PostCompact", trigger="auto", compact_summary="the PRIVATE summary")
        self.assertNotIn("PRIVATE", result.stderr)
        self.assertEqual(self.events()[1], self.event(
            "compaction_confirmed", "confirmed", attempt=1, trigger="auto", confirmation=True,
            **self.observed(42000, "below"),
        ))
        self.assertNotIn("PRIVATE", self.box.compaction_events_path.read_text())
        self.assertEqual(self.box.fifo_lines(), [])

    def test_post_compact_without_a_reduction_is_unconfirmed(self):
        cases = (("still above", 151000, "above"), ("exactly at", THRESHOLD, "exact"), ("unknown", None, "unknown"))
        for name, tokens, state in cases:
            with self.subTest(name):
                self.setUp()
                if tokens is not None:
                    self.tokens(tokens)
                self.run_event("PreCompact", trigger="auto")
                self.run_event("PostCompact", trigger="auto")
                self.assertEqual(self.events()[1], self.event(
                    "compaction_unconfirmed", "unconfirmed", attempt=1, trigger="auto",
                    failure_reason="native_context_not_reduced", **self.observed(tokens, state),
                ))

    def test_post_compact_without_an_attempt_reports_attempt_one(self):
        self.tokens(42000)
        self.run_event("PostCompact", trigger="manual")
        self.assertEqual(self.events(), [self.event(
            "compaction_confirmed", "confirmed", attempt=1, trigger="manual", confirmation=True,
            **self.observed(42000, "below"),
        )])

    def test_later_event_below_the_threshold_confirms_an_unconfirmed_compaction(self):
        cases = (("UserPromptSubmit", "busy", {"prompt": "next request"}), ("Stop", "provider_native", {}))
        for event, idle_boundary, fields in cases:
            with self.subTest(event):
                self.setUp()
                self.tokens(151000)
                self.run_event("PreCompact", trigger="auto")
                self.run_event("PostCompact", trigger="auto")
                self.tokens(42000)
                self.run_event(event, **fields)
                self.run_event(event, **fields)
                confirmed, later = self.events()[2:]
                self.assertEqual(confirmed, self.event(
                    "compaction_confirmed", "confirmed", attempt=1, confirmation=True,
                    idle_boundary=idle_boundary, **self.observed(42000, "below"),
                ))
                self.assertEqual((later["stage"], later["attempt"], later["confirmation"]),
                                 ("active_context_observed", None, False))

    def test_later_event_above_the_threshold_leaves_the_compaction_unconfirmed(self):
        self.tokens(151000)
        self.run_event("PreCompact", trigger="auto")
        self.run_event("PostCompact", trigger="auto")
        self.run_event("Stop")
        self.assertEqual(self.events()[2], self.event(
            "active_context_observed", "idle", **self.observed(151000, "above"),
        ))

    def test_prompt_submit_and_stop_record_the_observed_context(self):
        self.tokens(90000)
        result = self.run_event("UserPromptSubmit", prompt="a PRIVATE request")
        self.assertNotIn("PRIVATE", result.stderr)
        self.run_event("Stop", last_assistant_message="a PRIVATE answer")
        self.assertEqual(self.events(), [
            self.event("active_context_observed", "busy", idle_boundary="busy", **self.observed(90000, "below")),
            self.event("active_context_observed", "idle", **self.observed(90000, "below")),
        ])
        self.assertNotIn("PRIVATE", self.box.compaction_events_path.read_text())

    def test_threshold_state_compares_the_context_with_the_configured_threshold(self):
        cases = (
            (None, 149999, THRESHOLD, "below"),
            (None, 150000, THRESHOLD, "exact"),
            (None, 150001, THRESHOLD, "above"),
            ("1000", 1000, 1000, "exact"),
            ("not-a-number", 149999, THRESHOLD, "below"),
            ("0", 1, 1, "exact"),
        )
        for configured, tokens, threshold, state in cases:
            with self.subTest(configured=configured, tokens=tokens):
                self.setUp()
                self.tokens(tokens)
                env = self.box.env(RELAY_AUTO_COMPACT_THRESHOLD_TOKENS=configured)
                self.run_event("PreCompact", trigger="auto", env=env)
                self.assertEqual(self.events(), [self.event(
                    "compaction_attempt", "started", attempt=1, trigger="auto",
                    threshold_tokens=threshold, **self.observed(tokens, state),
                )])

    def test_trigger_is_recorded_in_lower_case(self):
        self.run_event("PreCompact", trigger=" Manual ")
        self.run_event("PreCompact")
        self.assertEqual([e["trigger"] for e in self.events()], ["manual", None])

    def test_compaction_events_do_not_need_foreground_ownership(self):
        env = self.box.env(RELAY_ACTOR_ROLE="voice_bridge", RELAY_FOREGROUND_GATE_HANDLE=None)
        self.run_event("PreCompact", trigger="auto", env=env)
        self.run_event("PostCompact", trigger="auto", env=env)
        self.assertEqual([e["stage"] for e in self.events()], ["compaction_attempt", "compaction_unconfirmed"])

    def test_stop_without_foreground_ownership_records_no_context(self):
        self.tokens(90000)
        self.run_event("Stop", env=self.box.env(RELAY_ACTOR_ROLE="voice_bridge"))
        self.assertEqual(self.events(), [])

    def test_events_fall_back_to_the_session_events_file(self):
        box = self.box
        self.run_event("PreCompact", trigger="auto", env=box.env(RELAY_CONTEXT_COMPACTION_EVENTS=None))
        self.assertEqual([e["stage"] for e in self.events(box.session_events_path)], ["compaction_attempt"])
        self.assertFalse(box.compaction_events_path.exists())

    def test_no_events_path_records_nothing(self):
        box = self.box
        env = box.env(RELAY_CONTEXT_COMPACTION_EVENTS=None, RELAY_SESSION_EVENTS=None)
        self.run_event("PreCompact", trigger="auto", env=env)
        self.run_event("PostCompact", trigger="auto", env=env)
        self.assertFalse(box.compaction_events_path.exists())
        self.assertFalse(box.session_events_path.exists())

    def test_unwritable_events_path_is_ignored(self):
        box = self.box
        missing = box.root / "missing-directory" / "events.jsonl"
        env = box.env(RELAY_CONTEXT_COMPACTION_EVENTS=str(missing))
        self.run_event("PreCompact", trigger="auto", env=env)
        self.run_event("PostCompact", trigger="auto", env=env)
        self.assertFalse(missing.parent.exists())
        self.assertEqual(box.fifo_lines(), [])

    def test_provider_is_unknown_without_a_provider_name(self):
        self.tokens(90000)
        self.run_event("PreCompact", trigger="auto", env=self.box.env(RELAY_RUNNER_PROVIDER=None))
        self.assertEqual(self.events(), [
            self.event("compaction_attempt", "started", attempt=1, trigger="auto", provider="unknown"),
        ])

    # -- transcript token parser ---------------------------------------------

    def test_missing_or_unreadable_transcript_gives_an_unknown_context(self):
        self.assertTokens(None)
        os.mkdir(str(self.box.transcript_path))
        self.assertTokens(None)

    def test_malformed_transcript_lines_are_skipped(self):
        self.box.write_transcript([
            self.token_record(61000),
            "{not json",
            "[1, 2, 3]",
            '"text"',
            "",
        ])
        self.assertTokens(61000)

    def test_transcript_without_token_records_gives_an_unknown_context(self):
        self.box.write_transcript([{"type": "user", "message": {"role": "user", "content": "hello"}}])
        self.assertTokens(None)

    def test_only_the_last_two_mebibytes_of_the_transcript_are_read(self):
        filler = json.dumps({"type": "padding", "text": "x" * 4000})
        padding = [filler] * (TAIL_BYTES // (len(filler) + 1) + 1)
        self.box.write_transcript([self.token_record(61000)] + padding)
        self.assertTokens(None)
        self.box.write_transcript([self.token_record(61000)] + padding[:-10])
        self.assertTokens(61000)


class ClaudeCompaction(CompactionContract, CompactionCase):
    provider = "claude"

    def token_record(self, tokens: int) -> dict:
        cached = min(tokens, 30)
        return claude_usage(tokens - cached, cache_creation=cached // 3, cache_read=cached - cached // 3)

    def tokens(self, tokens: int) -> None:
        self.box.write_transcript([self.token_record(tokens)])

    def test_context_is_input_plus_cache_tokens_of_the_newest_assistant_message(self):
        self.box.write_transcript([
            claude_usage(1000, 2000, 3000),
            claude_usage(10, 200, 3000),
            {"type": "user", "message": {"role": "user", "content": "thanks"}},
        ])
        self.assertTokens(3210)

    def test_sidechain_and_usage_free_messages_are_skipped(self):
        self.box.write_transcript([
            claude_usage(70000),
            claude_usage(5, isSidechain=True),
            {"type": "assistant", "message": {"role": "assistant", "content": []}},
            {"type": "assistant", "message": {"role": "assistant", "usage": {"output_tokens": 9}}},
            {"type": "assistant", "message": "not an object"},
        ])
        self.assertTokens(70000)

    def test_missing_usage_components_count_as_zero(self):
        self.box.write_transcript([
            {"type": "assistant", "message": {"usage": {"cache_read_input_tokens": 812, "input_tokens": True}}},
        ])
        self.assertTokens(812)

    def test_newer_compact_boundary_reports_its_post_compaction_tokens(self):
        self.box.write_transcript([claude_usage(151000), claude_compact_boundary(38000)])
        self.assertTokens(38000)
        self.box.write_transcript([claude_compact_boundary(38000), claude_usage(52000)])
        self.assertTokens(52000)

    def test_compact_boundary_without_post_tokens_is_skipped(self):
        self.box.write_transcript([claude_usage(151000), claude_compact_boundary()])
        self.assertTokens(151000)

    def test_stop_failure_records_the_failed_turn(self):
        self.tokens(90000)
        self.run_event("StopFailure", error="rate_limit")
        self.run_event("PreCompact", trigger="auto")
        self.run_event("PreCompact", trigger="auto")
        self.run_event("StopFailure", error="e" * 200)
        self.run_event("StopFailure", error={"type": "overloaded"})
        failures = [e for e in self.events() if e["stage"] == "provider_turn_failed"]
        self.assertEqual(failures, [
            self.event("provider_turn_failed", "failed", attempt=1, failure_reason="rate_limit",
                       **self.observed(90000, "below")),
            self.event("provider_turn_failed", "failed", attempt=2, failure_reason="e" * 80,
                       **self.observed(90000, "below")),
            self.event("provider_turn_failed", "failed", attempt=2, **self.observed(90000, "below")),
        ])

    def test_stop_failure_without_foreground_ownership_records_nothing(self):
        self.run_event("StopFailure", error="rate_limit", env=self.box.env(RELAY_ACTOR_ROLE="voice_bridge"))
        self.assertEqual(self.events(), [])

    def test_codex_token_records_are_not_read_for_claude(self):
        self.box.write_transcript([codex_token_count(61000)])
        self.assertTokens(None)


class CodexCompaction(CompactionContract, CompactionCase):
    provider = "codex"

    def token_record(self, tokens: int) -> dict:
        return codex_token_count(tokens)

    def tokens(self, tokens: int) -> None:
        self.box.write_transcript([self.token_record(tokens)])

    def test_context_is_the_last_token_usage_of_the_newest_token_count(self):
        self.box.write_transcript([
            codex_token_count(30000),
            codex_token_count(47000),
            {"type": "event_msg", "payload": {"type": "agent_message", "message": "done"}},
            {"type": "response_item", "payload": {"type": "message"}},
        ])
        self.assertTokens(47000)

    def test_token_count_without_usage_info_is_skipped(self):
        self.box.write_transcript([
            codex_token_count(47000),
            codex_token_count(0, info=False),
            {"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 9}}}},
            {"type": "event_msg", "payload": "not an object"},
        ])
        self.assertTokens(47000)

    def test_bare_token_count_record_is_accepted(self):
        self.box.write_transcript([
            {"type": "token_count", "info": {"last_token_usage": {"total_tokens": 52000}}},
        ])
        self.assertTokens(52000)

    def test_claude_usage_records_are_not_read_for_codex(self):
        self.box.write_transcript([claude_usage(61000)])
        self.assertTokens(None)


if __name__ == "__main__":
    unittest.main()
