"""Timing contract: every lifecycle hook finishes inside the providers' timeout.

Both providers stop a hook after 2 seconds. The budget can be tightened with
`RELAY_HOOK_BUDGET_SECONDS`. The measured latency is printed on stderr so the
runs of two implementations can be compared.
"""

from __future__ import annotations

import json
import os
import statistics
import sys
import unittest

from hook_contract_support import HOOK_BUDGET_SECONDS, ContractCase

ROUNDS = 5
TRANSCRIPT_BYTES = 3 * 1024 * 1024


class TimingContract:
    def first_events(self) -> list:
        return []

    def test_every_lifecycle_hook_finishes_within_the_budget(self):
        box = self.box
        # The slowest honest input: a session binding to write, a process to
        # identify, and a long transcript whose tail holds no token record.
        env = box.binding_env(RELAY_PROVIDER_PROCESS_ID=os.getpid())
        line = json.dumps({"type": "response_item", "payload": {"type": "message", "text": "x" * 2000}})
        box.write_transcript([line] * (TRANSCRIPT_BYTES // len(line)))

        samples = []

        def run(payload: dict) -> None:
            result = box.hook(payload, env=env)
            self.assertQuietSuccess(result)
            samples.append((result.elapsed, payload["hook_event_name"]))

        for payload in self.first_events():
            run(payload)
        for index in range(ROUNDS):
            turn = "turn-%d" % index
            box.claim(index + 1, "request %d" % index)
            run(box.payload("UserPromptSubmit", turn=turn, prompt="request %d" % index))
            run(box.payload("Stop", turn=turn, last_assistant_message="answer %d" % index))
            run(box.payload("PreCompact", trigger="auto"))
            run(box.payload("PostCompact", trigger="auto"))
        # The hooks did their work: each turn was bound and answered.
        self.assertEqual(len(box.fifo_lines()), 2 * ROUNDS)
        self.assertEqual(
            [row["state"] for row in box.rows("provider_turns")], ["completed_final"] * ROUNDS
        )
        self.assertEqual(len(box.jsonl(box.compaction_events_path)), 4 * ROUNDS)

        median = statistics.median(elapsed for elapsed, _ in samples)
        slowest, event = max(samples)
        sys.stderr.write(
            "\nhook latency (%s): median %.0f ms, slowest %.0f ms (%s), %d invocations, budget %.0f ms\n"
            % (self.provider, median * 1000, slowest * 1000, event, len(samples), HOOK_BUDGET_SECONDS * 1000)
        )
        self.assertLessEqual(
            slowest, HOOK_BUDGET_SECONDS,
            "%s took %.0f ms; the budget is %.0f ms" % (event, slowest * 1000, HOOK_BUDGET_SECONDS * 1000),
        )


class ClaudeTiming(TimingContract, ContractCase):
    provider = "claude"

    def first_events(self) -> list:
        return [self.box.payload("SessionStart", source="startup")]


class CodexTiming(TimingContract, ContractCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
