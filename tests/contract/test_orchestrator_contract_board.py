"""Artifact-backed board writes: claim-next-id, ticket write and delete, attachments.

Each write is one commit on refs/heads/relay/artifacts. The golden case walks
one project through every kind of write and compares each commit with a golden
tree byte for byte; the other cases share a second project and check the
responses, the `.orchestrator/` projection and the error cases.
"""

from __future__ import annotations

import base64
import unittest

from orchestrator_contract_support import (
    ARTIFACT_REF, DaemonCase, b64, git, ticket_markdown,
)

PNG = b"\x89PNG\r\n\x1a\ncontract-attachment"


class BoardCase(DaemonCase):
    @classmethod
    def prepare(cls):
        cls.repo = cls.box.artifact_project(
            "shared", tickets=[("CT-1", {"status": "backlog"})], next_id=2,
        )
        cls.legacy = cls.box.make_repo("legacy")

    def scope(self, repo=None, **extra) -> dict:
        repo = repo or self.repo
        body = {"repo_path": str(repo), "project_scope_token": self.box.scope_token(repo)}
        body.update(extra)
        return body

    def head(self, repo=None) -> str:
        return git(repo or self.repo, "rev-parse", ARTIFACT_REF)

    def assertProjectionMatchesRef(self, repo=None) -> None:
        """Every blob on the artifact ref is materialised unchanged in the working tree."""
        repo = repo or self.repo
        record = self.box.commit_record(repo)
        expected = {path: content for path, (_mode, content) in record["files"].items()}
        projection = {
            str(path.relative_to(repo)): path.read_bytes()
            for path in sorted((repo / ".orchestrator").rglob("*")) if path.is_file()
        }
        self.assertEqual(projection, expected)
        # The projection never shows up as a source change.
        self.assertEqual(git(repo, "status", "--porcelain", "--untracked-files=all"), "")

    def write(self, ticket_id: str, markdown: str, repo=None, **extra):
        return self.box.post("/v1/artifacts/tickets/write", self.scope(
            repo, ticket_id=ticket_id, markdown_base64=b64(markdown), **extra,
        ))

    def attach(self, ticket_id: str, repo=None, **overrides):
        body = self.scope(
            repo, ticket_id=ticket_id, filename="design.png", mime_type="image/png",
            content_base64=b64(PNG),
        )
        body.update(overrides)
        return self.box.post("/v1/artifacts/attachments/write", body)


class GoldenBoardTests(BoardCase):
    """One project, every kind of board write, each commit against a golden tree."""

    def test_every_board_write_commits_the_golden_tree(self):
        repo = self.box.artifact_project(
            "board", tickets=[("CT-1", {"status": "backlog"})], next_id=2,
        )

        # The migration command's bootstrap commit and the source-branch cutover.
        self.box.assert_golden_commit("board/1-bootstrap", repo)
        self.assertProjectionMatchesRef(repo)
        self.assertEqual(git(repo, "ls-files", ".orchestrator"), "")
        self.assertEqual(
            git(repo, "log", "-1", "--format=%s"), "Stop tracking Relay artifact materialization",
        )

        def step(name: str, response, status: int) -> dict:
            self.assertStatus(response, status)
            self.assertEqual(response.json["artifact_commit"], self.head(repo))
            payload = dict(response.json)
            if "markdown_base64" in payload:
                payload["markdown_base64"] = "<base64 of the ticket blob in the golden tree>"
            self.box.assert_golden_json("board/%s.response" % name, payload)
            self.box.assert_golden_commit("board/%s" % name, repo)
            self.assertProjectionMatchesRef(repo)
            return response.json

        before = self.head(repo)
        claim = step("2-claim-next-id", self.box.post(
            "/v1/artifacts/tickets/claim-next-id", self.scope(repo, request_id="claim-1"),
        ), 201)
        self.assertEqual(claim["ticket_id"], "CT-2")
        self.assertEqual(git(repo, "rev-parse", ARTIFACT_REF + "^"), before)

        written = step("3-ticket-write", self.write(
            "CT-2", ticket_markdown("CT-2"), repo, request_id="write-1",
        ), 200)
        self.assertEqual(
            git(repo, "show", ARTIFACT_REF + ":.orchestrator/CT-2.md", binary=True),
            base64.b64decode(written["markdown_base64"]),
        )

        step("4-attachment-write", self.attach("CT-2", repo, request_id="attach-1"), 200)
        self.assertEqual(
            git(repo, "show", ARTIFACT_REF + ":.orchestrator/attachments/CT-2/design.png", binary=True),
            PNG,
        )

        step("5-ticket-rewrite", self.write(
            "CT-1", ticket_markdown("CT-1", title="Edited after migration", priority="high"),
            repo, request_id="write-2",
        ), 200)

        deleted = step("6-ticket-delete", self.box.post(
            "/v1/artifacts/tickets/delete", self.scope(repo, ticket_id="CT-2", request_id="delete-1"),
        ), 200)
        self.assertEqual(len(deleted["warnings"]), 1)
        paths = git(repo, "ls-tree", "-r", "--name-only", ARTIFACT_REF).splitlines()
        self.assertNotIn(".orchestrator/CT-2.md", paths)
        self.assertNotIn(".orchestrator/attachments/CT-2/design.png", paths)

        # Six commits, each with exactly one parent after the root.
        self.assertEqual(git(repo, "rev-list", "--count", ARTIFACT_REF), "6")
        self.assertEqual(git(repo, "rev-list", "--merges", "--count", ARTIFACT_REF), "0")


class ClaimNextIdTests(BoardCase):
    def test_claim_returns_the_id_and_bumps_the_counter(self):
        before = self.head()
        response = self.assertStatus(
            self.box.post("/v1/artifacts/tickets/claim-next-id", self.scope()), 201,
        )
        claimed = response.json["id"]
        self.assertEqual(response.json["ticket_id"], "CT-%d" % claimed)
        self.assertEqual(response.json["prefix"], "CT")
        self.assertIs(response.json["idempotent"], False)
        self.assertEqual(response.json["artifact_commit"], self.head())
        self.assertEqual(git(self.repo, "rev-parse", ARTIFACT_REF + "^"), before)
        config = git(self.repo, "show", ARTIFACT_REF + ":.orchestrator/config.toml")
        self.assertIn("next_id = %d" % (claimed + 1), config.splitlines())
        self.assertProjectionMatchesRef()

    def test_consecutive_claims_never_repeat_an_id(self):
        ids = [
            self.assertStatus(
                self.box.post("/v1/artifacts/tickets/claim-next-id", self.scope()), 201,
            ).json["id"]
            for _ in range(3)
        ]
        self.assertEqual(ids, [ids[0], ids[0] + 1, ids[0] + 2])

    def test_reusing_a_request_id_for_a_second_claim_is_a_conflict(self):
        self.assertStatus(self.box.post(
            "/v1/artifacts/tickets/claim-next-id", self.scope(request_id="claim-repeat"),
        ), 201)
        head = self.head()
        body = self.assertError(
            self.box.post("/v1/artifacts/tickets/claim-next-id", self.scope(request_id="claim-repeat")),
            409, "already committed with different content",
        )
        self.assertIs(body["retryable"], False)
        self.assertEqual(self.head(), head)

    def test_claim_without_a_scope_token_is_rejected(self):
        head = self.head()
        self.assertError(
            self.box.post("/v1/artifacts/tickets/claim-next-id", {"repo_path": str(self.repo)}),
            422, "requires a confirmed project scope token",
        )
        self.assertEqual(self.head(), head)

    def test_claim_with_a_malformed_scope_token_is_rejected(self):
        self.assertError(
            self.box.post("/v1/artifacts/tickets/claim-next-id",
                          {"repo_path": str(self.repo), "project_scope_token": "not-base64!"}),
            422, "malformed",
        )

    def test_claim_with_a_token_for_another_project_is_rejected(self):
        token = self.box.scope_token(self.repo, projectID="another-project")
        self.assertError(
            self.box.post("/v1/artifacts/tickets/claim-next-id",
                          {"repo_path": str(self.repo), "project_scope_token": token}),
            422, "stale projectID",
        )

    def test_claim_with_a_token_for_another_path_is_rejected(self):
        token = self.box.scope_token(self.repo, repositoryPath=str(self.legacy))
        self.assertError(
            self.box.post("/v1/artifacts/tickets/claim-next-id",
                          {"repo_path": str(self.repo), "project_scope_token": token}),
            422, "stale repositoryPath",
        )

    def test_claim_with_an_outdated_registry_timestamp_is_rejected(self):
        token = self.box.scope_token(self.repo, registryRecordUpdatedAt=1.0)
        self.assertError(
            self.box.post("/v1/artifacts/tickets/claim-next-id",
                          {"repo_path": str(self.repo), "project_scope_token": token}),
            422, "token is stale",
        )

    def test_claim_on_a_legacy_board_is_rejected(self):
        self.assertError(
            self.box.post("/v1/artifacts/tickets/claim-next-id", {"repo_path": str(self.legacy)}),
            400, "not using the artifact-backed board writer",
        )


class TicketWriteTests(BoardCase):
    def test_write_adds_only_the_daemon_owned_fields(self):
        sent = ticket_markdown("CT-20")
        response = self.assertStatus(self.write("CT-20", sent), 200)
        stored = base64.b64decode(response.json["markdown_base64"]).decode("utf-8")
        lines = stored.splitlines()
        self.assertEqual(lines[1], "id: CT-20")
        self.assertRegex(lines[2], r"^artifact_id: ticket-[0-9a-f]{40}$")
        self.assertRegex(lines[3], r"^user_edited_at: \d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$")
        # Everything the caller sent survives after those two lines.
        self.assertEqual(lines[:2] + lines[4:], sent.splitlines())
        self.assertEqual(response.json["ticket_id"], "CT-20")
        self.assertIs(response.json["idempotent"], False)
        self.assertEqual(response.json["artifact_commit"], self.head())
        self.assertProjectionMatchesRef()

    def test_rewrite_keeps_the_artifact_id_and_refreshes_the_edit_time(self):
        first = self.assertStatus(self.write("CT-21", ticket_markdown("CT-21")), 200).json
        second = self.assertStatus(
            self.write("CT-21", ticket_markdown("CT-21", title="Renamed", status="ready")), 200,
        ).json
        before = base64.b64decode(first["markdown_base64"]).decode("utf-8").splitlines()
        after = base64.b64decode(second["markdown_base64"]).decode("utf-8").splitlines()
        self.assertEqual(before[2], after[2])
        self.assertIn('title: "Renamed"', after)
        self.assertIn("status: ready", after)
        self.assertNotEqual(first["artifact_commit"], second["artifact_commit"])
        self.assertEqual(git(self.repo, "rev-parse", ARTIFACT_REF + "^"), first["artifact_commit"])

    def test_write_with_mismatched_id_is_rejected(self):
        head = self.head()
        self.assertError(
            self.write("CT-99", ticket_markdown("CT-22")), 400,
            "ticket write ID does not match markdown frontmatter",
        )
        self.assertEqual(self.head(), head)

    def test_write_with_invalid_base64_is_rejected(self):
        self.assertError(
            self.box.post("/v1/artifacts/tickets/write",
                          self.scope(ticket_id="CT-23", markdown_base64="***")),
            400, "ticket write payload is invalid",
        )

    def test_write_without_frontmatter_is_rejected(self):
        self.assertError(
            self.write("CT-24", "## Description\n\nNo frontmatter.\n"), 400,
            "ticket write payload is invalid",
        )

    def test_write_without_a_scope_token_is_rejected(self):
        self.assertError(
            self.box.post("/v1/artifacts/tickets/write", {
                "repo_path": str(self.repo), "ticket_id": "CT-25",
                "markdown_base64": b64(ticket_markdown("CT-25")),
            }),
            422, "requires a confirmed project scope token",
        )

    def test_write_on_a_legacy_board_is_rejected(self):
        self.assertError(
            self.box.post("/v1/artifacts/tickets/write", {
                "repo_path": str(self.legacy), "ticket_id": "CT-26",
                "markdown_base64": b64(ticket_markdown("CT-26")),
            }),
            400, "not using the artifact-backed board writer",
        )


class AttachmentTests(BoardCase):
    def test_attachment_is_committed_and_projected(self):
        self.assertStatus(self.write("CT-30", ticket_markdown("CT-30")), 200)
        response = self.assertStatus(self.attach("CT-30"), 200)
        self.assertEqual(response.json, {
            "ticket_id": "CT-30", "filename": "design.png",
            "artifact_commit": self.head(), "idempotent": False,
        })
        self.assertEqual(
            git(self.repo, "show", ARTIFACT_REF + ":.orchestrator/attachments/CT-30/design.png",
                binary=True),
            PNG,
        )
        self.assertProjectionMatchesRef()

    def test_repeating_the_same_attachment_request_is_idempotent(self):
        self.assertStatus(self.write("CT-31", ticket_markdown("CT-31")), 200)
        first = self.assertStatus(self.attach("CT-31", request_id="attach-repeat"), 200).json
        second = self.assertStatus(self.attach("CT-31", request_id="attach-repeat"), 200).json
        self.assertIs(second["idempotent"], True)
        self.assertEqual(second["artifact_commit"], first["artifact_commit"])
        self.assertEqual(self.head(), first["artifact_commit"])

    def test_attachment_for_an_unknown_ticket_is_rejected(self):
        self.assertError(
            self.attach("CT-404"), 400, "attachment owner ticket does not exist: CT-404",
        )

    def test_attachment_with_invalid_base64_is_rejected(self):
        self.assertError(
            self.attach("CT-1", content_base64="***"), 400, "attachment content is not valid base64",
        )

    def test_attachment_with_a_path_in_its_name_is_rejected(self):
        head = self.head()
        self.assertError(self.attach("CT-1", filename="../escape.png"), 422)
        self.assertEqual(self.head(), head)

    def test_attachment_without_a_scope_token_is_rejected(self):
        self.assertError(
            self.box.post("/v1/artifacts/attachments/write", {
                "repo_path": str(self.repo), "ticket_id": "CT-1", "filename": "design.png",
                "mime_type": "image/png", "content_base64": b64(PNG),
            }),
            422, "requires a confirmed project scope token",
        )


class TicketDeleteTests(BoardCase):
    def test_delete_removes_the_ticket_and_its_attachments(self):
        self.assertStatus(self.write("CT-40", ticket_markdown("CT-40")), 200)
        self.assertStatus(self.attach("CT-40"), 200)
        response = self.assertStatus(
            self.box.post("/v1/artifacts/tickets/delete", self.scope(ticket_id="CT-40")), 200,
        )
        self.assertEqual(response.json["ticket_id"], "CT-40")
        self.assertIs(response.json["idempotent"], False)
        self.assertEqual(response.json["artifact_commit"], self.head())
        paths = git(self.repo, "ls-tree", "-r", "--name-only", ARTIFACT_REF).splitlines()
        self.assertNotIn(".orchestrator/CT-40.md", paths)
        self.assertNotIn(".orchestrator/attachments/CT-40/design.png", paths)
        self.assertProjectionMatchesRef()

    def test_deleting_a_missing_ticket_is_idempotent_and_writes_nothing(self):
        head = self.head()
        response = self.assertStatus(
            self.box.post("/v1/artifacts/tickets/delete", self.scope(ticket_id="CT-404")), 200,
        )
        self.assertEqual(response.json, {
            "ticket_id": "CT-404", "artifact_commit": head, "idempotent": True, "warnings": [],
        })
        self.assertEqual(self.head(), head)

    def test_delete_without_a_scope_token_is_rejected(self):
        self.assertError(
            self.box.post("/v1/artifacts/tickets/delete",
                          {"repo_path": str(self.repo), "ticket_id": "CT-1"}),
            422, "requires a confirmed project scope token",
        )

    def test_delete_on_a_legacy_board_is_rejected(self):
        self.assertError(
            self.box.post("/v1/artifacts/tickets/delete",
                          {"repo_path": str(self.legacy), "ticket_id": "CT-1"}),
            400,
        )


if __name__ == "__main__":
    unittest.main()
