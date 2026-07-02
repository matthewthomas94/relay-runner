from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from pm_frontstage import (  # noqa: E402
    BackstageOutcome,
    DelegationRequest,
    OrchestrationTraceEvent,
    PMFrontstagePrototype,
    PMUpdateMode,
    PMUpdateRun,
    PMUpdateSnapshot,
    PMStatusEvent,
    RelayCommandMetadata,
    build_pm_update_snapshot,
)


def relay_command(seq: int = 1, command_id: str = "cmd-1") -> dict:
    return {
        "relay_command_seq": seq,
        "relay_command_id": command_id,
        "provider": "codex",
    }


class PMFrontstageTests(unittest.TestCase):
    def test_status_event_contract_is_public_and_structured(self):
        command = RelayCommandMetadata.from_dict(
            relay_command(7, "cmd-7"),
            source_text="dispatch RR-7 with hidden details",
        )

        event = PMStatusEvent(
            phase="outcome",
            message="The PM can dispatch the worker.",
            source="orchestrator",
            command=command,
            run_id=42,
            ticket_id="rr-7",
        )

        payload = event.to_dict()
        self.assertEqual(payload["phase"], "outcome")
        self.assertEqual(payload["message"], "The PM can dispatch the worker.")
        self.assertEqual(payload["source"], "orchestrator")
        self.assertEqual(payload["ticket_id"], "RR-7")
        self.assertEqual(payload["run_id"], 42)
        self.assertEqual(payload["command"]["relay_command_seq"], 7)
        self.assertEqual(payload["command"]["relay_command_id"], "cmd-7")
        self.assertEqual(payload["command"]["provider"], "codex")
        self.assertNotIn("source_text", payload["command"])
        self.assertNotIn("reasoning", payload)

    def test_orchestration_trace_contract_is_curated_and_public(self):
        command = RelayCommandMetadata.from_dict(
            relay_command(8, "cmd-8"),
            source_text="create RR-8 with private transcript text",
        )

        event = OrchestrationTraceEvent(
            kind="dispatch-claimed",
            command=command,
            ticket_id="rr-8",
            run_id=51,
        )

        payload = event.to_dict()
        self.assertEqual(payload["kind"], "dispatch-claimed")
        self.assertEqual(payload["message"], "RR-8 run 51 claimed")
        self.assertEqual(payload["ticket_id"], "RR-8")
        self.assertEqual(payload["run_id"], 51)
        self.assertEqual(payload["command"]["relay_command_id"], "cmd-8")
        self.assertNotIn("source_text", payload["command"])
        self.assertLessEqual(len(payload["message"]), 96)

        status_event = event.to_status_event_dict()
        self.assertEqual(status_event["phase"], "planning")
        self.assertEqual(status_event["message"], payload["message"])

    def test_orchestration_trace_rejects_raw_command_like_messages(self):
        with self.assertRaisesRegex(ValueError, "raw commands"):
            OrchestrationTraceEvent(
                kind="board-change",
                message="git status && cat secret.txt",
            )

    def test_acknowledgement_is_emitted_before_backstage_planning(self):
        order: list[str] = []

        def planner(source_text, command_fields, repo_path):
            del source_text, command_fields, repo_path
            order.append("planner")
            return BackstageOutcome.execute_solo(
                "The PM can answer directly.",
                solo_action="inline work explicitly requested",
            )

        runner = PMFrontstagePrototype(
            backstage_planner=planner,
            current_command_reader=lambda: relay_command(),
            emit=lambda event: order.append(event.phase),
        )

        result = runner.handle_voice_command(
            "fix this inline",
            relay_command(),
            repo_path="/tmp/repo",
        )

        self.assertEqual(order, ["acknowledged", "planning", "planner", "outcome"])
        self.assertEqual(result.outcome.kind, "execute_solo")
        self.assertFalse(result.stale)

    def test_default_planner_returns_pm_controlled_delegate_plan(self):
        with tempfile.TemporaryDirectory() as tmp:
            command = relay_command(3, "cmd-3")
            runner = PMFrontstagePrototype(
                current_command_reader=lambda: command,
            )

            result = runner.handle_voice_command(
                "dispatch RR-7 to a worker",
                command,
                repo_path=tmp,
            )

        outcome = result.outcome
        self.assertEqual(outcome.kind, "delegate_plan")
        self.assertEqual(outcome.max_parallel_workers, 1)
        request = outcome.delegation_requests[0]
        self.assertIsInstance(request, DelegationRequest)
        self.assertTrue(request.pm_controls_dispatch)
        self.assertEqual(request.ticket_id, "RR-7")
        self.assertEqual(request.to_dispatch_payload(), {
            "ticket_id": "RR-7",
            "repo_path": str(Path(tmp).resolve()),
            "relay_command_seq": 3,
            "relay_command_id": "cmd-3",
        })
        self.assertEqual(result.status_events[-1].ticket_id, "RR-7")

    def test_delegation_request_carries_worker_creation_metadata(self):
        command = RelayCommandMetadata.from_dict(
            relay_command(9, "cmd-9"),
            source_text="dispatch the refined plan",
        )

        request = DelegationRequest(
            ticket_id="rr-9",
            repo_path="/tmp/repo",
            summary="Dispatch refined ticket RR-9",
            command=command,
            dependency_assumptions=("rr-8",),
            worker_model="strong",
            worker_effort="high",
            worker_sizing_rationale="Cross-module worker request.",
            worker_provider_notes="Codex uses model_reasoning_effort; Claude uses --effort.",
            dispatcher_context="Use the refined ticket only.",
        )

        payload = request.to_dict()
        self.assertEqual(payload["ticket_id"], "RR-9")
        self.assertEqual(payload["dependency_assumptions"], ["RR-8"])
        self.assertEqual(payload["worker_model"], "strong")
        self.assertEqual(payload["worker_effort"], "high")
        self.assertEqual(payload["dispatch_payload"]["context"], "Use the refined ticket only.")
        self.assertEqual(payload["dispatch_payload"]["relay_command_seq"], 9)
        self.assertNotIn("source_text", payload["dispatch_payload"])

    def test_default_planner_exposes_all_outcome_shapes(self):
        inline = PMFrontstagePrototype().handle_voice_command(
            "fix it inline",
            relay_command(1, "inline"),
            repo_path="/tmp/repo",
        )
        needs_user = PMFrontstagePrototype().handle_voice_command(
            "hello there",
            relay_command(2, "needs-user"),
            repo_path="/tmp/repo",
        )

        self.assertEqual(inline.outcome.kind, "execute_solo")
        self.assertEqual(needs_user.outcome.kind, "needs_user")
        self.assertTrue(needs_user.outcome.question)

    def test_stale_command_stops_before_backstage_planning(self):
        planner_calls = 0

        def planner(source_text, command_fields, repo_path):
            nonlocal planner_calls
            del source_text, command_fields, repo_path
            planner_calls += 1
            return BackstageOutcome.execute_solo("Should not run.", solo_action="no-op")

        runner = PMFrontstagePrototype(
            backstage_planner=planner,
            current_command_reader=lambda: relay_command(2, "newer"),
        )

        result = runner.handle_voice_command(
            "dispatch RR-7",
            relay_command(1, "older"),
            repo_path="/tmp/repo",
        )

        self.assertEqual(planner_calls, 0)
        self.assertTrue(result.stale)
        self.assertIsNone(result.outcome)
        self.assertEqual([event.phase for event in result.status_events], [
            "acknowledged",
            "stale",
        ])

    def test_stale_command_stops_delegate_plan_after_backstage_planning(self):
        current = relay_command(1, "cmd-1")
        command = RelayCommandMetadata.from_dict(current, source_text="dispatch RR-7")

        def planner(source_text, command_fields, repo_path):
            del source_text, command_fields
            current.update(relay_command(2, "newer"))
            return BackstageOutcome.delegate_plan(
                "The PM can dispatch one worker.",
                [
                    DelegationRequest(
                        ticket_id="RR-7",
                        repo_path=str(repo_path),
                        summary="dispatch ticket RR-7",
                        command=command,
                    )
                ],
            )

        runner = PMFrontstagePrototype(
            backstage_planner=planner,
            current_command_reader=lambda: current,
        )

        result = runner.handle_voice_command(
            "dispatch RR-7",
            relay_command(1, "cmd-1"),
            repo_path="/tmp/repo",
        )

        self.assertTrue(result.stale)
        self.assertIsNone(result.outcome)
        self.assertEqual([event.phase for event in result.status_events], [
            "acknowledged",
            "planning",
            "stale",
        ])

    def test_cli_harness_streams_status_events_and_outcome(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = subprocess.run(
                [
                    sys.executable,
                    os.path.join(SERVICES, "pm_frontstage.py"),
                    "--command",
                    "dispatch RR-7 to a worker",
                    "--seq",
                    "4",
                    "--id",
                    "cmd-4",
                    "--repo",
                    tmp,
                ],
                check=True,
                text=True,
                capture_output=True,
            )

        lines = [json.loads(line) for line in proc.stdout.splitlines()]
        self.assertEqual(lines[0]["status_event"]["phase"], "acknowledged")
        self.assertEqual(lines[1]["status_event"]["phase"], "planning")
        self.assertEqual(lines[2]["status_event"]["phase"], "outcome")
        self.assertEqual(lines[3]["outcome"]["kind"], "delegate_plan")
        dispatch_payload = lines[3]["outcome"]["delegation_requests"][0]["dispatch_payload"]
        self.assertEqual(dispatch_payload["relay_command_seq"], 4)
        self.assertEqual(dispatch_payload["relay_command_id"], "cmd-4")
        self.assertIn("Codex", lines[3]["provider_parity"])
        self.assertIn("Claude", lines[3]["provider_parity"])

    def test_build_pm_update_snapshot_uses_durable_repo_scoped_sources(self):
        snapshot = build_pm_update_snapshot(
            repo_path="/tmp/repo",
            provider="codex",
            session_id=7,
            sessions_payload={
                "orchestrator_sessions": [
                    {"id": 7, "repo_path": "/tmp/repo", "provider_key": "codex", "state": "awaiting_workers"},
                    {"id": 8, "repo_path": "/tmp/other", "provider_key": "codex", "state": "idle"},
                ]
            },
            runs_payload={
                "runs": [
                    {"id": 21, "repo_path": "/tmp/repo", "ticket_id": "rr-9", "state": "Running", "activity": "Running tests", "provider_key": "codex"},
                    {"id": 22, "repo_path": "/tmp/repo", "ticket_id": "rr-10", "state": "Failed", "activity": "cat secret.txt", "provider_key": "codex"},
                    {"id": 23, "repo_path": "/tmp/other", "ticket_id": "rr-11", "state": "Running", "activity": "Other repo", "provider_key": "codex"},
                ]
            },
            program_payload={
                "items": [
                    {
                        "project": {"path": "/tmp/repo"},
                        "open_tickets": 4,
                        "blocked": 1,
                        "awaiting_merge": 2,
                        "stale_runs": 1,
                    }
                ]
            },
        )

        self.assertEqual(snapshot.session_state, "awaiting_workers")
        self.assertEqual(snapshot.active_runs, (
            PMUpdateRun(ticket_id="RR-9", run_id=21, state="Running", activity="Running tests"),
        ))
        self.assertEqual(snapshot.blocked_tickets, 1)
        self.assertEqual(snapshot.awaiting_merge, 2)
        self.assertEqual(snapshot.stale_runs, 1)
        self.assertEqual(snapshot.open_tickets, 4)

    def test_pm_update_mode_emits_on_meaningful_change_and_cadence(self):
        command = RelayCommandMetadata.from_dict(relay_command(10, "cmd-10"))
        notifications: list[PMStatusEvent] = []
        snapshots = iter([
            PMUpdateSnapshot(session_state="planning"),
            PMUpdateSnapshot(
                session_state="awaiting_workers",
                active_runs=(PMUpdateRun(ticket_id="RR-9", run_id=51, state="Running", activity="Running tests"),),
            ),
            PMUpdateSnapshot(
                session_state="awaiting_workers",
                active_runs=(PMUpdateRun(ticket_id="RR-9", run_id=51, state="Running", activity="Running tests"),),
            ),
        ])
        mode = PMUpdateMode(
            command=command,
            status_reader=lambda: next(snapshots),
            current_command_reader=lambda: relay_command(10, "cmd-10"),
            emit=notifications.append,
            cadence_seconds=5,
            startup_grace_seconds=2,
        )
        mode.started_at = 100.0

        first = mode.poll(now=100.0)
        second = mode.poll(now=103.0)
        third = mode.poll(now=109.0)

        self.assertTrue(first.continue_running)
        self.assertIsNone(first.emitted_event)
        self.assertEqual(second.state, "awaiting_workers")
        self.assertEqual(second.emitted_event.message, "RR-9 run 51: Running tests")
        self.assertEqual(third.state, "awaiting_workers")
        self.assertEqual(third.emitted_event.message, "RR-9 run 51: Running tests")
        self.assertEqual(len(notifications), 2)

    def test_pm_update_mode_stops_when_newer_command_takes_over(self):
        command = RelayCommandMetadata.from_dict(relay_command(11, "cmd-11"))
        mode = PMUpdateMode(
            command=command,
            status_reader=lambda: PMUpdateSnapshot(session_state="planning"),
            current_command_reader=lambda: relay_command(12, "newer"),
        )
        mode.started_at = 100.0

        result = mode.poll(now=100.0)

        self.assertFalse(result.continue_running)
        self.assertTrue(result.stale)
        self.assertEqual(result.state, "stale")

    def test_pm_update_mode_keeps_status_messages_public_and_bounded(self):
        command = RelayCommandMetadata.from_dict(relay_command(13, "cmd-13"))
        message_log: list[str] = []
        mode = PMUpdateMode(
            command=command,
            status_reader=lambda: PMUpdateSnapshot(
                session_state="awaiting_workers",
                active_runs=(
                    PMUpdateRun(
                        ticket_id="RR-13",
                        run_id=99,
                        state="Running",
                        activity="Reading source files while raw transcript text stays private and very long for clipping verification",
                    ),
                ),
            ),
            current_command_reader=lambda: relay_command(13, "cmd-13"),
            emit=lambda event: message_log.append(event.message),
            cadence_seconds=30,
            startup_grace_seconds=0,
        )
        mode.started_at = 200.0

        result = mode.poll(now=200.0)

        self.assertTrue(result.continue_running)
        self.assertLessEqual(len(message_log[0]), 120)
        self.assertNotIn("transcript", result.emitted_event.message.lower())
        self.assertNotIn("source_text", result.emitted_event.to_dict()["command"])


if __name__ == "__main__":
    unittest.main()
