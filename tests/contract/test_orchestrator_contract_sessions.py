"""Foreground sessions, voice commands, orchestrator actions, program capture,
spike follow-ups, messenger outcomes, continuity, General tasks and personal
storage: the success paths behind the routes the voice bridge, the MCP server
and the app call.
"""

from __future__ import annotations

import json
import unittest

from orchestrator_contract_support import ARTIFACT_REF, DaemonCase, git


class SessionTests(DaemonCase):
    @classmethod
    def prepare(cls):
        cls.repo = cls.box.make_repo("pm", next_id=7)
        cls.box.write_ticket(cls.repo, "CT-1")

    def ensure(self, **extra):
        return self.box.post("/v1/orchestrator-session/ensure", {
            "repo_path": str(self.repo), "provider": "claude", **extra,
        })

    def current_command(self, seq: int, command_id: str) -> None:
        """What the voice bridge writes when it claims a command."""
        (self.box.runtime / "voice_command_state.json").write_text(json.dumps({
            "relay_command_seq": seq, "relay_command_id": command_id,
        }))

    def test_session_lifecycle(self):
        created = self.assertStatus(self.ensure(source="contract"), 201).json
        session = created["orchestrator_session"]
        self.assertIs(session["created"], True)
        self.assertEqual((session["provider_key"], session["state"]), ("claude", "idle"))
        self.box.assert_golden_json("sessions/ensure.response", created)
        again = self.assertStatus(self.ensure(), 200).json["orchestrator_session"]
        self.assertEqual(again["id"], session["id"])
        self.assertIs(again["created"], False)

        beat = self.assertStatus(self.box.post("/v1/orchestrator-session/heartbeat", {
            "session_id": session["id"], "state": "planning",
        }), 200).json
        self.assertEqual(beat["orchestrator_session"]["state"], "planning")
        self.assertError(
            self.box.post("/v1/orchestrator-session/heartbeat", {"session_id": session["id"], "state": "busy"}),
            400, "invalid orchestrator state 'busy'",
        )
        listed = self.box.get("/v1/orchestrator-sessions", repo_path=str(self.repo)).json
        self.assertEqual([item["id"] for item in listed["orchestrator_sessions"]], [session["id"]])

        # A command is recorded only while the bridge says it is the current one.
        body = {"repo_path": str(self.repo), "source_text": "Status please.", "relay_command_seq": 1,
                "relay_command_id": "contract-1", "session_id": session["id"], "provider": "claude"}
        self.assertError(
            self.box.post("/v1/orchestrator-session/command", body), 400,
            "stale Relay command: no mutation authorization was registered",
        )
        self.current_command(1, "contract-1")
        recorded = self.assertStatus(self.box.post("/v1/orchestrator-session/command", body), 202).json
        self.box.assert_golden_json("sessions/command.response", recorded)
        rows = self.box.rows("orchestrator_commands.db", "SELECT relay_command_id FROM orchestrator_commands")
        self.assertIn({"relay_command_id": "contract-1"}, rows)

        stopped = self.assertStatus(self.box.post("/v1/orchestrator-session/stop", {
            "session_id": session["id"], "reason": "contract",
        }), 200).json["orchestrator_session"]
        self.assertEqual((stopped["state"], stopped["stop_reason"]), ("stopped", "contract"))

    def test_orchestrator_actions_author_a_legacy_ticket(self):
        response = self.assertStatus(self.box.post("/v1/orchestrator-actions", {
            "repo_path": str(self.repo), "request_id": "action-1",
            "actions": [{
                "kind": "create_ticket", "title": "Made by an action", "description": "Do it.",
                "acceptance_criteria": ["It is done."], "worker_model": "balanced",
                "worker_effort": "medium", "worker_sizing_rationale": "Small and scripted.",
                "worker_provider_notes": "none",
            }],
        }), 202).json
        self.assertEqual(response["tickets_written"], [{"ticket_id": "CT-7", "action": "create_ticket"}])
        self.box.assert_golden_json("sessions/orchestrator-actions.response", response)
        self.assertEqual((self.repo / ".orchestrator" / "CT-7.md").read_text(), (
            "---\nid: CT-7\ntitle: Made by an action\nstatus: backlog\npriority: medium\n"
            "execution_mode: implementation\ndepends_on: []\nrun_id: null\ncanceled: false\n"
            "order: 7\nworker_model: balanced\nworker_effort: medium\n"
            "worker_sizing_rationale: Small and scripted.\nworker_provider_notes: none\n---\n"
            "## Description\n\nDo it.\n\n## Acceptance criteria\n\n- [ ] It is done.\n"
        ))
        self.assertIn("next_id = 8", (self.repo / ".orchestrator" / "config.toml").read_text())
        self.assertEqual(git(self.repo, "status", "--porcelain"), "")
        self.assertError(self.box.post("/v1/orchestrator-actions", {
            "repo_path": str(self.repo), "actions": [{"kind": "launch_rockets"}],
        }), 400, "invalid orchestrator action kind: 'launch_rockets'")
        self.assertError(
            self.box.post("/v1/orchestrator-actions", {"repo_path": str(self.repo), "actions": []}),
            400, "actions must be a non-empty list",
        )

    def test_continuity_observation_and_messenger_routes(self):
        observed = self.assertStatus(self.box.post("/v1/continuity/observation", {
            "source": "bridge", "event": "command_received", "session_id": "app-session-1",
            "provider": "claude",
        }), 202).json
        self.assertIsInstance(observed, dict)
        self.assertError(self.box.post("/v1/continuity/observation", {
            "source": "bridge", "event": "teleported", "session_id": "app-session-1",
        }), 400, "unsupported continuity lifecycle event")
        self.assertEqual(self.box.get("/v1/messenger/outcomes").json, {"outcomes": []})
        self.assertStatus(self.box.post("/v1/messenger/outcomes/12345/attempt"), 202)
        self.assertEqual(
            self.assertStatus(self.box.post("/v1/messenger/outcomes/12345/delivered"), 404).json,
            {"outcome": None},
        )


class ProgramAndFollowupTests(DaemonCase):
    @classmethod
    def prepare(cls):
        cls.repo = cls.box.artifact_project("program", tickets=[
            ("CT-1", {"execution_mode": "spike"}),
        ], next_id=2)

    def scope(self, **extra) -> dict:
        return {"repo_path": str(self.repo), "project_scope_token": self.box.scope_token(self.repo), **extra}

    def test_capture_status_and_dashboard(self):
        captured = self.assertStatus(self.box.post("/v1/program/capture", self.scope(
            entries=[{"kind": "decision", "text": "Ship the contract suite."}],
            capture_id="capture-1", provider="claude",
        )), 201).json
        self.assertEqual(captured["capture_id"], "capture-1")
        self.assertEqual(captured["counts"], {"Decision": 1})
        self.assertEqual(captured["durable_authority"], "relay/artifacts")
        self.assertEqual(
            git(self.repo, "rev-parse", ARTIFACT_REF), captured["artifact_commit"],
        )
        self.assertError(self.box.post("/v1/program/capture", self.scope()), 400, "entries is required")

        status = self.assertStatus(self.box.get("/v1/program/status"), 200).json
        self.assertEqual(status["counts"], {"projects": 1, "items": 1})
        self.assertEqual(status["items"][0]["project"]["path"], str(self.repo))
        dashboard = self.assertStatus(self.box.get("/v1/program/dashboard", sweep=0), 200).json
        self.assertIn("summary", dashboard)

    def test_spike_followups_are_proposed_and_reviewed(self):
        run = self.assertStatus(self.box.post("/v1/runs", self.scope(ticket_id="CT-1")), 202).json["run"]
        self.box.wait_for_run(run["id"], "SpikeCompleted")
        body = {"origin_repo_path": str(self.repo), "origin_ticket_id": "CT-1",
                "origin_run_id": run["id"], "provider": "claude"}
        proposed = self.assertStatus(self.box.post("/v1/spikes/follow-ups/propose", body), 201).json
        batch = proposed["batch"]
        self.assertEqual(len(batch["proposals"]), 1)
        self.assertEqual(batch["proposals"][0]["state"], "draft")
        self.box.assert_golden_json("sessions/followups-propose.response", proposed)
        again = self.assertStatus(self.box.post("/v1/spikes/follow-ups/propose", body), 200).json
        self.assertEqual(again["batch"]["id"], batch["id"])

        proposal = batch["proposals"][0]
        route = "/v1/spikes/follow-ups/%s/proposals/%s/review" % (batch["id"], proposal["id"])
        self.assertError(self.box.post(route, {"decision": "maybe"}), 400)
        reviewed = self.assertStatus(self.box.post(route, {"decision": "reject"}), 200).json
        self.assertEqual(reviewed["rejected"], proposal["id"])
        self.assertEqual(reviewed["batch"]["proposals"][0]["state"], "rejected")
        # A decided proposal answers any later review as a duplicate.
        repeat = self.assertStatus(self.box.post(route, {"decision": "accept"}), 200).json
        self.assertIs(repeat["duplicate"], True)
        # Rejecting writes no ticket.
        self.assertFalse((self.repo / ".orchestrator" / "CT-2.md").exists())

    def test_queue_drain_reconcile(self):
        result = self.assertStatus(self.box.post("/v1/queue-drain/reconcile", {
            "repo_path": str(self.repo), "trigger": "contract",
        }), 200).json
        self.assertEqual(result["trigger"], "contract")
        self.assertEqual([project["repo_path"] for project in result["projects"]], [str(self.repo)])


class GeneralTaskTests(DaemonCase):
    def test_general_task_is_created_run_reviewed(self):
        body = {"title": "Draft", "description": "Write a draft.",
                "acceptance_criteria": ["A draft exists."], "request_id": "general-1"}
        created = self.assertStatus(self.box.post("/v1/general/tasks", body), 201).json
        task = created["task"]
        self.assertEqual((task["scope"], task["status"]), ("general", "backlog"))
        self.assertIs(created["idempotent"], False)
        self.assertIs(self.assertStatus(self.box.post("/v1/general/tasks", body), 201).json["idempotent"], True)

        dispatched = self.assertStatus(
            self.box.post("/v1/general/tasks/%s/dispatch" % task["id"], {}), 202,
        ).json
        self.assertIs(dispatched["already_active"], False)
        waiting = self.box.wait_for(
            lambda: (lambda current: current if current["status"] == "awaiting_review" else None)(
                self.box.get("/v1/general/tasks/%s" % task["id"]).json["task"]),
            message="general task awaiting review",
        )
        run = waiting["runs"][0]
        self.assertEqual(run["provider"], "claude")
        self.assertEqual([item["path"] for item in run["artifact_manifest"]], ["output.md"])
        self.assertTrue(run["workspace_path"].startswith(str(self.box.state_root / "files" / "tasks")))

        self.assertError(
            self.box.post("/v1/general/tasks/%s/review" % task["id"], {"run_id": run["id"]}), 400,
            "Review requires approve true/false and an evidence-based summary",
        )
        reviewed = self.assertStatus(self.box.post("/v1/general/tasks/%s/review" % task["id"], {
            "run_id": run["id"], "approve": True, "summary": "output.md covers the criterion.",
        }), 200).json
        self.assertEqual(reviewed["task"]["status"], "done")
        listed = self.box.get("/v1/general/tasks").json
        self.assertEqual((listed["total_count"], listed["scope"]), (1, "general"))
        self.assertError(self.box.post("/v1/general/tasks", {"title": "x"}), 400,
                         "title, description and request_id are required")


class PersonalStorageTests(DaemonCase):
    def test_local_only_status_files_and_policy(self):
        status = self.assertStatus(self.box.get("/v1/personal-storage/status"), 200).json
        self.assertEqual((status["state"], status["connected"]), ("local_only", False))
        self.assertEqual(status["files_root"], str(self.box.state_root / "files"))
        self.assertEqual(self.box.get("/v1/personal-storage/files").json, {"files": []})
        policy = self.assertStatus(self.box.post("/v1/personal-storage/policy", {
            "budget_bytes": 128 * 1024 * 1024, "retention_days": 7,
        }), 200).json
        self.assertEqual((policy["budget_bytes"], policy["retention_days"]), (128 * 1024 * 1024, 7))
        self.assertError(self.box.post("/v1/personal-storage/configure", {}), 409,
                         "Enable private GitHub storage explicitly before creating a repository.")
        # The account lookup asks gh, which the fake answers as signed out.
        self.assertStatus(self.box.get("/v1/personal-storage/account"), 409)
        self.assertTrue(self.box.invocations(role="gh"))


if __name__ == "__main__":
    unittest.main()
