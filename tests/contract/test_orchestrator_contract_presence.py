"""Agent presence (RR-525): attributed mutations, the presence routes and notices.

A session runs while `<runtime>/relay-sessions/<key>/` holds a `session_agent`
file, as the app writes it. Each case starts the sessions it needs and stops
them afterwards, so the shared daemon's record carries nothing between cases.
"""

from __future__ import annotations

import shutil
import unittest

from orchestrator_contract_support import DaemonCase, b64, ticket_markdown

TERMINAL = ("Merged", "Failed", "Canceled", "AwaitingReview", "VerificationBlocked",
            "IntegrationBlocked")


class PresenceCase(DaemonCase):
    @classmethod
    def prepare(cls):
        cls.repo = cls.box.make_repo("presence-runs")
        cls.box.write_ticket(cls.repo, "CT-1")
        cls.board = cls.box.artifact_project(
            "presence-board", tickets=[("CT-1", {"status": "backlog"})], next_id=2,
        )
        cls.general = cls.box.state_root / "general-tasks"
        cls.general.mkdir(parents=True, exist_ok=True)

    def start(self, key: str, agent: str) -> str:
        spool = self.box.runtime / "relay-sessions" / key
        spool.mkdir(parents=True)
        (spool / "session_agent").write_text(agent + "\n")
        self.addCleanup(self.stop, key)
        return key

    def stop(self, key: str) -> None:
        shutil.rmtree(self.box.runtime / "relay-sessions" / key, ignore_errors=True)
        # A sweep forgets the stopped session before the next case.
        self.box.get("/v1/agent-presence")

    def claim(self, key: str) -> list:
        response = self.assertStatus(
            self.box.post("/v1/agent-notices/claim", {"relay_session_key": key}), 200,
        )
        return [notice["text"] for notice in response.json["notices"]]

    def presence_of(self, slug: str) -> dict:
        agents = self.assertStatus(self.box.get("/v1/agent-presence"), 200).json["agents"]
        return next(agent for agent in agents if agent["agent"] == slug)

    def repositories(self, slug: str) -> list:
        return [(repo["name"], repo["source"], repo["detail"]) for repo in self.presence_of(slug)["repositories"]]

    def board_body(self, **extra) -> dict:
        body = {"repo_path": str(self.board), "project_scope_token": self.box.scope_token(self.board)}
        body.update(extra)
        return body


class AttributedMutationTests(PresenceCase):
    def test_a_dispatch_with_a_session_key_records_the_repository_and_tells_the_others(self):
        puck = self.start("puck-dispatch", "puck")
        george = self.start("george-dispatch", "george")
        response = self.assertStatus(self.box.post("/v1/runs", {
            "ticket_id": "CT-1", "repo_path": str(self.repo), "dispatcher_session_key": george,
        }), 202)
        self.box.wait_for_run(response.json["run"]["id"], *TERMINAL)

        self.assertEqual(self.repositories("george"), [("presence-runs", "dispatch", "dispatched CT-1")])
        self.assertEqual(self.claim(puck), [
            "Agent notice: George started working in presence-runs (dispatched CT-1).",
        ])
        self.assertEqual(self.claim(george), [])
        self.assertEqual(self.claim(puck), [])

    def test_a_ticket_write_records_presence_only_with_a_session_key(self):
        puck = self.start("puck-write", "puck")
        sky = self.start("sky-write", "sky")
        markdown = ticket_markdown("CT-1", title="Rewritten without a key")
        self.assertStatus(self.box.post("/v1/artifacts/tickets/write", self.board_body(
            ticket_id="CT-1", markdown_base64=b64(markdown),
        )), 200)
        self.assertEqual(self.repositories("sky"), [])
        self.assertEqual(self.claim(puck), [])

        markdown = ticket_markdown("CT-1", title="Rewritten by Sky")
        self.assertStatus(self.box.post("/v1/artifacts/tickets/write", self.board_body(
            ticket_id="CT-1", markdown_base64=b64(markdown), relay_session_key=sky,
        )), 200)
        self.assertEqual(self.repositories("sky"), [("presence-board", "ticket_write", "wrote ticket CT-1")])
        self.assertEqual(self.claim(puck), [
            "Agent notice: Sky started working in presence-board (wrote ticket CT-1).",
        ])

        # More activity in the same repository is not news.
        claimed = self.assertStatus(self.box.post(
            "/v1/artifacts/tickets/claim-next-id", self.board_body(relay_session_key=sky),
        ), 201).json
        self.assertTrue(claimed["ticket_id"].startswith("CT-"))
        self.assertEqual(self.claim(puck), [])

    def test_a_claim_with_a_session_key_records_presence(self):
        puck = self.start("puck-claim", "puck")
        isabella = self.start("isabella-claim", "isabella")
        claimed = self.assertStatus(self.box.post(
            "/v1/artifacts/tickets/claim-next-id", self.board_body(relay_session_key=isabella),
        ), 201).json
        detail = "claimed ticket id %s" % claimed["ticket_id"]
        self.assertEqual(self.repositories("isabella"), [("presence-board", "ticket_claim", detail)])
        self.assertEqual(self.claim(puck), [
            "Agent notice: Isabella started working in presence-board (%s)." % detail,
        ])


class PresenceToolTests(PresenceCase):
    def test_declare_adds_the_repository_with_its_note_and_read_returns_all_four_agents(self):
        puck = self.start("puck-declare", "puck")
        george = self.start("george-declare", "george")
        declared = self.assertStatus(self.box.post("/v1/agent-presence/declare", {
            "relay_session_key": george, "repo_path": str(self.repo),
            "note": "reading the bridge code\nand more",
        }), 200).json
        self.assertEqual(declared["declared"], "entered")
        self.assertEqual(declared["notices"], [])

        read = self.assertStatus(self.box.post("/v1/agent-presence", {"relay_session_key": puck}), 200).json
        self.assertEqual([agent["name"] for agent in read["agents"]], ["Puck", "Isabella", "George", "Sky"])
        self.assertEqual([agent["running"] for agent in read["agents"]], [True, False, True, False])
        repository = read["agents"][2]["repositories"][0]
        self.assertEqual(
            (repository["name"], repository["source"], repository["note"]),
            ("presence-runs", "declared", "reading the bridge code"),
        )
        self.assertEqual(read["agents"][2]["last_activity"], repository["last_seen"])
        self.assertIsNone(read["agents"][1]["last_activity"])
        # The read tool delivered Puck's notice; it is not delivered again.
        self.assertEqual([notice["text"] for notice in read["notices"]], [
            "Agent notice: George started working in presence-runs (reading the bridge code).",
        ])
        self.assertTrue(read["notice_block"].startswith("Agent notices ("))
        self.assertEqual(self.claim(puck), [])

    def test_general_tasks_is_never_recorded(self):
        puck = self.start("puck-general", "puck")
        george = self.start("george-general", "george")
        declared = self.assertStatus(self.box.post("/v1/agent-presence/declare", {
            "relay_session_key": george, "repo_path": str(self.general), "note": "a draft",
        }), 200).json
        self.assertEqual(declared["declared"], "ignored")
        self.assertEqual(self.repositories("george"), [])
        self.assertEqual(self.claim(puck), [])

    def test_a_stopped_agent_is_reported_with_the_repositories_it_left(self):
        puck = self.start("puck-stop", "puck")
        george = self.start("george-stop", "george")
        self.assertStatus(self.box.post("/v1/agent-presence/declare", {
            "relay_session_key": george, "repo_path": str(self.repo), "note": "reviewing",
        }), 200)
        self.claim(puck)
        self.stop(george)
        self.assertFalse(self.presence_of("george")["running"])
        self.assertEqual(self.claim(puck), ["Agent notice: George stopped and left presence-runs."])

    def test_declare_needs_a_running_session_and_a_directory(self):
        self.assertError(self.box.post("/v1/agent-presence/declare", {}), 400,
                         "relay_session_key is required")
        self.assertError(self.box.post("/v1/agent-presence/declare", {
            "relay_session_key": "nobody", "repo_path": str(self.repo), "note": "x",
        }), 400, "names no running Relay agent session")
        george = self.start("george-errors", "george")
        self.assertError(self.box.post("/v1/agent-presence/declare", {
            "relay_session_key": george, "repo_path": str(self.box.root / "nowhere"), "note": "x",
        }), 400, "is not a directory")
        self.assertError(self.box.post("/v1/agent-notices/claim", {"relay_session_key": "Bad Key"}),
                         400, "invalid relay_session_key")

    def test_startup_text_leaves_out_the_starting_agent(self):
        self.start("george-startup", "george")
        text = self.assertStatus(self.box.get("/v1/agent-presence", exclude_agent="puck"), 200).json[
            "startup_text"]
        self.assertTrue(text.startswith("Agent presence when this session started"), text)
        self.assertIn("- George is running; no repository recorded.", text)
        self.assertNotIn("Puck", text)


if __name__ == "__main__":
    unittest.main()
