"""The global notes library, artifact history and retention.

Notes live in their own git repository under the state root (`notes/`) and
every change is one commit on its refs/heads/relay/artifacts. The lifecycle
case walks one note through create, checkpoint, generated metadata, a
metadata retry, archive and delete, comparing each commit with a golden tree.
"""

from __future__ import annotations

import base64
import unittest

from orchestrator_contract_support import ARTIFACT_REF, DaemonCase, git

T0 = "2026-08-04T05:00:00Z"
T1 = "2026-08-04T05:01:00Z"
FIRST = {"segment_id": "s1", "captured_at": T0, "text": "We decided to ship the contract suite.",
         "start_ms": 0, "end_ms": 1200, "speaker": None}
SECOND = {"segment_id": "s2", "captured_at": T1, "text": "The port follows next quarter.",
          "start_ms": 1200, "end_ms": 2000, "speaker": None}


def create_body(request_id: str, **overrides) -> dict:
    body = {
        "repo_path": "", "request_id": request_id, "created_at": T0, "capture_started_at": T0,
        "captured_at": T0, "recording_state": "recording", "checkpoint_reason": "checkpoint",
        "segments": [FIRST], "capture_ended_at": None, "provider": "claude",
    }
    body.update(overrides)
    return body


class NoteCase(DaemonCase):
    @property
    def notes_repo(self):
        return self.box.state_root / "notes"

    def note(self, identity: str) -> dict:
        return self.assertStatus(self.box.get("/v1/artifacts/notes/%s" % identity), 200).json

    def complete(self, identity: dict, request_id: str):
        update = {
            "identity": identity, "captured_at": T1, "recording_state": "completed",
            "checkpoint_reason": "complete", "segments": [FIRST, SECOND], "capture_ended_at": T1,
        }
        return self.box.post("/v1/artifacts/notes/%s/update" % identity["note_id"], {
            "repo_path": "", "request_id": request_id, "update": update, "provider": "claude",
        })

    def wait_for_metadata(self, note_id: str, state: str = "ready") -> dict:
        return self.box.wait_for(
            lambda: (lambda note: note if note["note"]["metadata"]["state"] == state else None)(
                self.note(note_id)),
            message="note %s metadata %s" % (note_id, state),
        )


class NoteLifecycleTests(NoteCase):
    def test_note_lifecycle_commits_the_golden_trees(self):
        created = self.assertStatus(self.box.post("/v1/artifacts/notes/create", create_body("c-1")), 201).json
        identity = created["note"]["identity"]
        self.assertEqual(identity["note_id"], "RR-N1")
        self.assertEqual(identity["project_id"], "global-notes")
        self.assertIs(created["idempotent"], False)
        self.assertEqual(created["note"]["metadata"]["state"], "pending")
        markdown = base64.b64decode(created["markdown_base64"])
        self.assertEqual(
            markdown, git(self.notes_repo, "show", "%s:.orchestrator/notes/RR-N1.md" % ARTIFACT_REF,
                          binary=True),
        )
        self.box.assert_golden_json("notes/create.response", created)
        self.box.assert_golden_commit("notes/1-create", self.notes_repo)

        # Repeating the request is idempotent and writes nothing.
        head = git(self.notes_repo, "rev-parse", ARTIFACT_REF)
        again = self.assertStatus(self.box.post("/v1/artifacts/notes/create", create_body("c-1")), 201).json
        self.assertIs(again["idempotent"], True)
        self.assertEqual(again["note"]["identity"], identity)
        self.assertEqual(git(self.notes_repo, "rev-parse", ARTIFACT_REF), head)

        updated = self.assertStatus(self.complete(identity, "u-1"), 200).json
        self.assertEqual(updated["note"]["recording_state"], "completed")
        self.assertEqual(len(updated["note"]["segments"]), 2)

        ready = self.wait_for_metadata("RR-N1")
        metadata = ready["note"]["metadata"]
        self.assertEqual(metadata["title"], "Scripted note title")
        self.assertEqual(metadata["summary"], "A scripted summary of the captured note.")
        self.assertEqual(metadata["provider"], "claude")
        self.assertEqual(metadata["source_sha256"], metadata["generated_source_sha256"])
        self.box.assert_golden_commit("notes/2-metadata", self.notes_repo)
        launch = self.box.invocations(role="note-metadata")[0]
        self.assertEqual(launch["stdin_keys"], ["relay_captured_transcript"])
        self.assertEqual(launch["argv"][:2], ["--print", "--safe-mode"])

        # The same note answers by note id and by artifact id.
        self.assertEqual(self.note(identity["artifact_id"])["note"], ready["note"])
        listed = self.assertStatus(self.box.get("/v1/artifacts/notes"), 200).json
        self.assertEqual([item["note_id"] for item in listed["notes"]], ["RR-N1"])
        self.assertEqual(listed["total_count"], 1)
        self.assertIs(listed["has_more"], False)
        self.box.assert_golden_json("notes/list.response", listed)

        # A retry regenerates metadata from the same source.
        self.box.plan("note-metadata", result={"title": "Retried title", "summary": "Retried summary."})
        retried = self.assertStatus(
            self.box.post("/v1/artifacts/notes/RR-N1/retry-metadata", {"repo_path": ""}), 200,
        ).json
        self.assertEqual(retried["note"]["metadata"]["state"], "pending")
        self.box.wait_for(
            lambda: self.note("RR-N1")["note"]["metadata"].get("title") == "Retried title",
            message="retried metadata",
        )

        archived = self.assertStatus(self.box.post("/v1/artifacts/notes/RR-N1/archive", {
            "repo_path": "", "artifact_id": identity["artifact_id"], "archived_at": T1,
            "request_id": "a-1", "provider": "claude",
        }), 200).json
        self.box.assert_golden_json("notes/archive.response", archived)
        self.box.assert_golden_commit("notes/3-archive", self.notes_repo)

        deleted = self.assertStatus(self.box.post("/v1/artifacts/notes/RR-N1/delete", {
            "repo_path": "", "artifact_id": identity["artifact_id"], "request_id": "d-1",
        }), 200).json
        self.assertIs(deleted["deleted"], True)
        self.box.assert_golden_commit("notes/4-delete", self.notes_repo)
        self.assertEqual(self.box.get("/v1/artifacts/notes").json["notes"], [])


class NoteErrorTests(NoteCase):
    def test_create_requires_a_request_id(self):
        self.assertError(
            self.box.post("/v1/artifacts/notes/create", create_body("")), 422,
            "note request_id must be 1 to 120 safe characters",
        )

    def test_unknown_and_malformed_note_ids(self):
        self.assertError(self.box.get("/v1/artifacts/notes/RR-N404"), 422, "no unique project note matches")
        self.assertError(
            self.box.post("/v1/artifacts/notes/not-a-note/delete", {"repo_path": ""}), 400,
            "invalid unpadded note ID: 'not-a-note'",
        )

    def test_update_needs_an_object(self):
        self.assertError(
            self.box.post("/v1/artifacts/notes/RR-N1/update", {"repo_path": "", "update": "x"}), 400,
            "note update must be an object",
        )

    def test_cancel_discards_a_recording(self):
        created = self.assertStatus(
            self.box.post("/v1/artifacts/notes/create", create_body("cancel-1")), 201,
        ).json
        identity = created["note"]["identity"]
        canceled = self.assertStatus(self.box.post(
            "/v1/artifacts/notes/%s/cancel" % identity["note_id"],
            {"repo_path": "", "artifact_id": identity["artifact_id"], "request_id": "cancel-2"},
        ), 200).json
        self.assertIs(canceled["deleted"], True)
        listed = self.box.get("/v1/artifacts/notes").json["notes"]
        self.assertNotIn(identity["note_id"], [item["note_id"] for item in listed])


class RetentionTests(DaemonCase):
    """A local-only artifact project: retention previews and reports but never archives.

    Twenty-seven done tickets is two over the retained limit of 25.
    """

    @classmethod
    def prepare(cls):
        cls.repo = cls.box.artifact_project("retained", tickets=[
            ("CT-%d" % number, {"status": "done"}) for number in range(1, 28)
        ], next_id=28)

    def scope(self, **extra) -> dict:
        body = {"repo_path": str(self.repo), "project_scope_token": self.box.scope_token(self.repo)}
        body.update(extra)
        return body

    def test_preview_status_and_storage(self):
        preview = self.assertStatus(
            self.box.get("/v1/artifacts/retention/preview", **self.scope()), 200,
        ).json
        self.assertEqual(preview["limit"], 25)
        self.assertEqual(preview["eviction_candidate_ids"], ["CT-2", "CT-1"])
        self.assertEqual(len(preview["retained_terminal_ids"]), 25)
        self.box.assert_golden_json("retention/preview.response", preview)
        status = self.assertStatus(
            self.box.get("/v1/artifacts/retention/status", **self.scope()), 200,
        ).json
        self.assertEqual(status["state"], "blocked")
        self.assertEqual(status["remote_mode"], "local_only")
        self.box.assert_golden_json("retention/status.response", status)
        storage = self.assertStatus(self.box.get("/v1/artifacts/storage", **self.scope()), 200)
        self.assertIsInstance(storage.json, dict)

    def test_apply_needs_a_request_id_and_writes_nothing_without_a_remote(self):
        self.assertError(
            self.box.post("/v1/artifacts/retention/apply", self.scope()), 400,
            "retention apply requires a stable request_id",
        )
        head = git(self.repo, "rev-parse", ARTIFACT_REF)
        self.assertError(
            self.box.post("/v1/artifacts/retention/apply", self.scope(request_id="r-1")), 422,
            "terminal cleanup remains preview-only until a GitHub remote is selected and confirmed",
        )
        self.assertEqual(git(self.repo, "rev-parse", ARTIFACT_REF), head)
        self.assertTrue((self.repo / ".orchestrator" / "CT-1.md").exists())

    def test_history_search_finds_nothing_archived(self):
        found = self.assertStatus(
            self.box.get("/v1/artifacts/history/search", query="CT-1", **self.scope()), 200,
        ).json
        self.assertEqual(found["history"], [])

    def test_rollout_reports_the_cohorts(self):
        rollout = self.assertStatus(self.box.get("/v1/artifacts/rollout"), 200).json
        self.assertEqual(rollout["status"], "available")
        self.assertIn("cohorts", rollout["rollout"])

    def test_dependency_summary(self):
        summary = self.assertStatus(
            self.box.get("/v1/artifacts/dependencies/CT-1", **self.scope()), 200,
        ).json
        self.box.assert_golden_json("retention/dependencies.response", summary)


if __name__ == "__main__":
    unittest.main()
