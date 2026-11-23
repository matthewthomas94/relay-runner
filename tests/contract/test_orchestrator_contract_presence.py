"""Agent presence (RR-525): attributed mutations, the presence routes and notices,
and the overlap and action notices between agents sharing a repository (RR-526).

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
        cls.box.write_ticket(cls.repo, "CT-2", title="Shared bridge fix")
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

    def declare(self, key: str, repo, note: str, **extra) -> dict:
        return self.assertStatus(self.box.post("/v1/agent-presence/declare", {
            "relay_session_key": key, "repo_path": str(repo), "note": note, **extra,
        }), 200).json

    def claim_until(self, key: str, predicate) -> list:
        """Claims `key`'s notices until `predicate` holds for all claimed so far."""
        claimed = []

        def probe():
            claimed.extend(self.claim(key))
            return predicate(claimed)
        self.box.wait_for(probe, message="agent notices for %s" % key)
        return claimed

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


class SharedRepositoryTests(PresenceCase):
    """RR-526: agents overlapping on a repository hear each other's actions."""

    def test_overlap_and_ticket_writes_reach_only_the_overlapping_agent(self):
        puck = self.start("puck-shared-board", "puck")
        george = self.start("george-shared-board", "george")
        isabella = self.start("isabella-shared-board", "isabella")
        self.declare(puck, self.board, "reviewing the board")
        self.claim(george)
        self.claim(isabella)

        claimed = self.assertStatus(self.box.post(
            "/v1/artifacts/tickets/claim-next-id", self.board_body(relay_session_key=george),
        ), 201).json
        ticket_id = claimed["ticket_id"]
        self.assertEqual(self.claim(puck), [
            "Agent notice: George started working in presence-board, where you are working too "
            "(claimed ticket id %s)." % ticket_id,
        ])
        self.assertEqual(self.claim(george), [
            "Agent notice: Puck is also working in presence-board (note: reviewing the board).",
        ])

        for title in ("Bridge fix", "Bridge fix, refined", "Bridge fix, sized", "Bridge fix, final"):
            self.assertStatus(self.box.post("/v1/artifacts/tickets/write", self.board_body(
                ticket_id=ticket_id, markdown_base64=b64(ticket_markdown(ticket_id, title=title)),
                relay_session_key=george,
            )), 200)
        # One created line, and three edits collapsed into one.
        self.assertEqual(self.claim(puck), [
            'Agent notice: George created ticket %s "Bridge fix" in presence-board.' % ticket_id,
            'Agent notice: George edited ticket %s "Bridge fix, final" in presence-board (3 edits).'
            % ticket_id,
        ])
        self.assertEqual(self.claim(george), [])
        # Isabella runs but is not in presence-board: only the RR-525 notice.
        self.assertEqual(self.claim(isabella), [
            "Agent notice: George started working in presence-board (claimed ticket id %s)." % ticket_id,
        ])
        george_board = self.presence_of("george")["repositories"][0]
        self.assertEqual(george_board["tickets"], [ticket_id])

    def test_a_dispatch_and_its_merge_reach_the_overlapping_agent(self):
        puck = self.start("puck-shared-runs", "puck")
        george = self.start("george-shared-runs", "george")
        isabella = self.start("isabella-shared-runs", "isabella")
        self.declare(george, self.repo, "fixing the bridge")
        self.declare(puck, self.repo, "reviewing the hook")
        for key in (puck, george, isabella):
            self.claim(key)

        response = self.assertStatus(self.box.post("/v1/runs", {
            "ticket_id": "CT-2", "repo_path": str(self.repo), "dispatcher_session_key": george,
        }), 202)
        self.box.wait_for_run(response.json["run"]["id"], "Merged")
        merged = "Agent notice: George's run of CT-2 in presence-runs merged into the checkout."
        notices = self.claim_until(puck, lambda claimed: merged in claimed)
        self.assertEqual(notices, [
            "Agent notice: George dispatched CT-2 in presence-runs.",
            merged,
        ])
        self.assertEqual(self.claim(isabella), [])
        self.assertEqual(self.claim(george), [])

    def test_declared_direct_work_carries_paths_and_returns_the_callers_notices(self):
        puck = self.start("puck-direct", "puck")
        george = self.start("george-direct", "george")
        self.declare(puck, self.repo, "editing the hook parser", paths=["rust/relay-rs/src/hook/mod.rs"])
        self.claim(puck)

        declared = self.declare(george, self.repo, "fixing the bridge prompt",
                                paths=["rust/relay-rs/src/bridge/relay.rs", "docs/agent-presence.md"])
        self.assertEqual(declared["declared"], "entered")
        # George learns of Puck's work at the moment he declares.
        self.assertEqual([notice["text"] for notice in declared["notices"]], [
            "Agent notice: Puck started working in presence-runs (editing the hook parser).",
            "Agent notice: Puck is also working in presence-runs (note: editing the hook parser).",
        ])
        self.assertEqual(self.claim(puck), [
            "Agent notice: George started working in presence-runs, where you are working too "
            "(note: fixing the bridge prompt).",
            "Agent notice: George declared direct work in presence-runs: fixing the bridge prompt "
            "(paths: rust/relay-rs/src/bridge/relay.rs, docs/agent-presence.md).",
        ])
        self.assertError(self.box.post("/v1/agent-presence/declare", {
            "relay_session_key": george, "repo_path": str(self.repo), "note": "x", "paths": "a",
        }), 400, "paths must be a list of strings")

    def test_the_overlap_ended_notice_follows_a_stop(self):
        puck = self.start("puck-overlap-stop", "puck")
        george = self.start("george-overlap-stop", "george")
        self.declare(george, self.repo, "fixing the bridge")
        self.declare(puck, self.repo, "reviewing the hook")
        self.claim(puck)
        self.stop(george)
        self.assertEqual(self.claim(puck), [
            "Agent notice: George stopped and left presence-runs. You no longer share "
            "presence-runs with George.",
        ])


if __name__ == "__main__":
    unittest.main()
