import base64
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier

from services.artifact_retention import ArtifactRetentionManager
from services.artifact_store import (
    ArtifactEventCollision,
    ArtifactIdentityError,
    ArtifactInjectedFailure,
    ArtifactMutation,
    ArtifactStore,
    ArtifactValidationError,
    ConfigWrite,
    NoteWrite,
    TicketWrite,
)
from services.note_contract import NOTE_MAX_BYTES
from services.project_notes import ProjectNoteManager
from services.tickets import scan_repo


CREATED = "2026-09-20T08:00:00Z"


class ProjectNoteTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-project-notes-")
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "--initial-branch=main", "--quiet")
        self.git("config", "user.name", "Note Tests")
        self.git("config", "user.email", "notes@example.invalid")
        (self.repo / "source.txt").write_text("source\n", encoding="utf-8")
        self.git("add", "source.txt")
        self.git("commit", "--quiet", "-m", "source base")
        self.source_head = self.git("rev-parse", "HEAD")
        self.store = ArtifactStore(
            self.repo,
            "project-notes",
            self.root / "state",
            enabled=True,
        )
        self.store.initialize(device_id="device-note-tests")
        self.set_config(prefix="PX")
        self.manager = ProjectNoteManager(self.store, device_id="device-note-tests")

    def tearDown(self):
        self.temporary.cleanup()

    def test_create_uses_independent_unpadded_counter_and_numeric_catalog_order(self):
        first = self.create("first")
        self.assertEqual(first["note"]["identity"]["note_id"], "PX-N1")
        self.assertNotIn("title:", self.markdown(first))
        config = self.config()
        self.assertEqual(config["next_id"], 1)
        self.assertEqual(config["next_note_id"], 2)

        second = self.create("second", second=1)
        self.set_config(next_note_id=10)
        tenth = self.create("tenth", second=2)
        self.set_config(next_id=9, next_note_id=999)
        nine_ninety_nine = self.create("nine-ninety-nine", second=3)
        one_thousand = self.create("one-thousand", second=4)
        self.assertEqual(second["note"]["identity"]["note_id"], "PX-N2")
        self.assertEqual(tenth["note"]["identity"]["note_id"], "PX-N10")
        self.assertEqual(nine_ninety_nine["note"]["identity"]["note_id"], "PX-N999")
        self.assertEqual(one_thousand["note"]["identity"]["note_id"], "PX-N1000")
        self.assertEqual(self.config()["next_id"], 9)
        self.assertEqual(
            [card["note_id"] for card in self.manager.list()["notes"]],
            ["PX-N1", "PX-N2", "PX-N10", "PX-N999", "PX-N1000"],
        )

        snapshot = self.store.snapshot()
        config_text = snapshot.files[".orchestrator/config.toml"].decode()
        ticket_config = config_text.replace("next_id = 9", "next_id = 10")
        ticket = b"---\nid: PX-9\nartifact_id: ticket-PX-9\ntitle: Work\nstatus: backlog\n---\n"
        self.store.mutate(ArtifactMutation(
            event_id="ticket-create",
            actor_type="user",
            device_id="device-note-tests",
            expected_base=snapshot.commit_id,
            operations=(ConfigWrite(ticket_config.encode()), TicketWrite("PX-9", "ticket-PX-9", ticket)),
        ))
        self.assertEqual(self.config()["next_note_id"], 1001)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.source_head)

    def test_create_and_update_retries_are_idempotent_and_preserve_identity(self):
        created = self.create("retry")
        retried = self.create("retry", provider="claude")
        self.assertTrue(retried["idempotent"])
        self.assertEqual(retried["note"]["identity"], created["note"]["identity"])
        self.assertEqual(self.config()["next_note_id"], 2)
        with self.assertRaises(ArtifactEventCollision):
            self.create("retry", text="different")

        def fail_after_ref(stage):
            if stage == "after_ref_update":
                raise ArtifactInjectedFailure(stage)

        failing_store = ArtifactStore(
            self.repo,
            "project-notes",
            self.root / "state",
            enabled=True,
            failure_injector=fail_after_ref,
        )
        failing_manager = ProjectNoteManager(failing_store, device_id="device-failure")
        with self.assertRaises(ArtifactInjectedFailure):
            failing_manager.create(
                request_id="create-after-ref",
                created_at="2026-09-20T08:00:01Z",
                capture_started_at="2026-09-20T08:00:01Z",
                captured_at="2026-09-20T08:00:01Z",
                recording_state="recording",
                checkpoint_reason="checkpoint",
                segments=[self.segment("segment-after-ref", "recover", second=1)],
            )
        self.assertFalse((self.repo / ".orchestrator/notes/PX-N2.md").exists())
        recovered = self.manager.create(
            request_id="create-after-ref",
            created_at="2026-09-20T08:00:01Z",
            capture_started_at="2026-09-20T08:00:01Z",
            captured_at="2026-09-20T08:00:01Z",
            recording_state="recording",
            checkpoint_reason="checkpoint",
            segments=[self.segment("segment-after-ref", "recover", second=1)],
        )
        self.assertTrue(recovered["idempotent"])
        self.assertTrue((self.repo / ".orchestrator/notes/PX-N2.md").exists())

        identity = created["note"]["identity"]
        update = {
            "identity": identity,
            "captured_at": "2026-09-20T08:05:00Z",
            "recording_state": "paused",
            "checkpoint_reason": "pause",
            "segments": [self.segment("segment-1", "corrected", second=5)],
        }
        saved = self.manager.update(request_id="pause-1", update=update, provider="codex")
        retry = self.manager.update(request_id="pause-1", update=update, provider="claude")
        self.assertTrue(retry["idempotent"])
        self.assertEqual(saved["note"], retry["note"])
        changed_identity = dict(identity)
        changed_identity["project_id"] = "another-project"
        with self.assertRaises(ArtifactIdentityError):
            self.manager.update(
                request_id="wrong-project",
                update={**update, "identity": changed_identity},
            )

    def test_concurrent_allocation_and_old_config_recovery_never_reuse_issued_ids(self):
        snapshot = self.store.snapshot()
        old_config = snapshot.files[".orchestrator/config.toml"].decode().replace(
            "next_note_id = 1\n", ""
        )
        self.store.mutate(ArtifactMutation(
            event_id="old-config",
            actor_type="migration",
            device_id="device-note-tests",
            expected_base=snapshot.commit_id,
            operations=(ConfigWrite(old_config.encode()),),
        ))

        start = Barrier(8)

        def create(index):
            manager = ProjectNoteManager(self.store, device_id=f"device-{index}")
            start.wait()
            return manager.create(
                request_id=f"concurrent-{index}",
                created_at=f"2026-09-20T08:00:0{index}Z",
                capture_started_at=f"2026-09-20T08:00:0{index}Z",
                captured_at=f"2026-09-20T08:00:0{index}Z",
                recording_state="recording",
                checkpoint_reason="checkpoint",
                segments=[self.segment(f"segment-{index}", f"text {index}", second=index)],
            )

        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(create, range(1, 9)))
        self.assertEqual(
            sorted(result["note"]["identity"]["note_id"] for result in results),
            [f"PX-N{number}" for number in range(1, 9)],
        )

        highest = next(result for result in results if result["note"]["identity"]["note_id"] == "PX-N8")
        identity = highest["note"]["identity"]
        archived = self.manager.archive(
            note_id="PX-N8",
            artifact_id=identity["artifact_id"],
            archived_at="2026-09-20T09:00:00Z",
            request_id="archive-highest",
        )
        self.assertFalse(archived["materialized"])
        self.set_config(next_note_id=1)
        next_note = self.create("after-archive", second=9)
        self.assertEqual(next_note["note"]["identity"]["note_id"], "PX-N9")

    def test_archived_history_is_verified_and_notes_never_enter_ticket_lifecycle(self):
        created = self.create("history", text="A durable meeting decision")
        identity = created["note"]["identity"]
        archived = self.manager.archive(
            note_id=identity["note_id"],
            artifact_id=identity["artifact_id"],
            archived_at="2026-09-20T09:00:00Z",
            request_id="archive-history",
        )
        self.assertFalse((self.repo / ".orchestrator/notes/PX-N1.md").exists())
        self.assertIn("durable meeting decision", self.markdown(archived))
        by_note_id = self.manager.get("PX-N1")
        by_artifact_id = self.manager.get(identity["artifact_id"])
        self.assertFalse(by_note_id["materialized"])
        self.assertEqual(by_note_id["note"], by_artifact_id["note"])
        self.assertEqual(scan_repo(self.repo), [])
        plan = ArtifactRetentionManager(self.store, enabled=True).preview()
        self.assertEqual(plan.nonterminal_ids, ())
        self.assertEqual(plan.retained_terminal_ids, ())

    def test_note_policy_accepts_long_transcript_but_failed_checkpoint_keeps_last_save(self):
        long_text = "raw_transcript: legitimate meeting words\n" + "x" * (300 * 1024)
        created = self.create("long-note", text=long_text)
        self.assertGreater(len(self.markdown(created).encode()), 256 * 1024)
        identity = created["note"]["identity"]
        head = self.store._head()
        with self.assertRaisesRegex(ArtifactValidationError, "limit"):
            self.manager.update(
                request_id="oversized-checkpoint",
                update={
                    "identity": identity,
                    "captured_at": "2026-09-20T08:10:00Z",
                    "recording_state": "paused",
                    "checkpoint_reason": "pause",
                    "segments": [self.segment("segment-large", "z" * NOTE_MAX_BYTES, second=10)],
                },
            )
        self.assertEqual(self.store._head(), head)
        self.assertEqual(self.manager.get(identity["note_id"])["note"], created["note"])

        with self.assertRaisesRegex(ArtifactValidationError, "private provider trace"):
            self.manager.update(
                request_id="private-trace-checkpoint",
                update={
                    "identity": identity,
                    "captured_at": "2026-09-20T08:11:00Z",
                    "recording_state": "paused",
                    "checkpoint_reason": "pause",
                    "segments": [self.segment(
                        "segment-private",
                        "hidden_reasoning: provider-only content",
                        second=11,
                    )],
                },
            )
        self.assertEqual(self.store._head(), head)

        ticket = (
            b"---\nid: PX-1\nartifact_id: ticket-PX-1\ntitle: Invalid\nstatus: backlog\n---\n\n"
            b"raw_transcript: legitimate meeting words\n"
        )
        with self.assertRaisesRegex(ArtifactValidationError, "raw transcript"):
            self.store.mutate(ArtifactMutation(
                event_id="ticket-raw-transcript",
                actor_type="pm",
                device_id="device-note-tests",
                expected_base=head,
                operations=(TicketWrite("PX-1", "ticket-PX-1", ticket),),
            ))

        content = base64.b64decode(created["markdown_base64"])
        with self.assertRaises(ArtifactValidationError):
            self.store.mutate(ArtifactMutation(
                event_id="note-traversal",
                actor_type="user",
                device_id="device-note-tests",
                expected_base=head,
                operations=(NoteWrite("../PX-N2", "note-invalid", "project-notes", content),),
            ))
        unsupported = content.replace(b"note_schema_version: 1", b"note_schema_version: 99")
        with self.assertRaisesRegex(ArtifactValidationError, "unsupported"):
            self.store.mutate(ArtifactMutation(
                event_id="note-unsupported-schema",
                actor_type="user",
                device_id="device-note-tests",
                expected_base=head,
                operations=(
                    NoteWrite(identity["note_id"], identity["artifact_id"], "project-notes", unsupported),
                ),
            ))
        self.assertEqual(self.store._head(), head)

    def create(self, request_id, *, text="meeting words", second=0, provider="codex"):
        timestamp = f"2026-09-20T08:00:{second:02d}Z"
        return self.manager.create(
            request_id=request_id,
            created_at=timestamp,
            capture_started_at=timestamp,
            captured_at=timestamp,
            recording_state="recording",
            checkpoint_reason="checkpoint",
            segments=[self.segment("segment-1", text, second=second)],
            provider=provider,
        )

    @staticmethod
    def segment(segment_id, text, *, second=0):
        return {
            "segment_id": segment_id,
            "captured_at": f"2026-09-20T08:00:{second:02d}Z",
            "text": text,
            "start_ms": second * 1000,
            "end_ms": second * 1000 + 500,
        }

    @staticmethod
    def markdown(response):
        return base64.b64decode(response["markdown_base64"]).decode("utf-8")

    def config(self):
        from services.toml_compat import tomllib
        return tomllib.loads(
            self.store.snapshot().files[".orchestrator/config.toml"].decode("utf-8")
        )

    def set_config(self, *, prefix=None, next_id=None, next_note_id=None):
        snapshot = self.store.snapshot()
        text = snapshot.files[".orchestrator/config.toml"].decode("utf-8")
        if prefix is not None:
            text = _replace_line(text, "prefix", f'prefix = "{prefix}"')
        if next_id is not None:
            text = _replace_line(text, "next_id", f"next_id = {next_id}")
        if next_note_id is not None:
            text = _replace_line(text, "next_note_id", f"next_note_id = {next_note_id}")
        sequence = self.git("rev-list", "--count", self.store.artifact_ref)
        self.store.mutate(ArtifactMutation(
            event_id=f"config-{sequence}-{next_id}-{next_note_id}-{prefix}",
            actor_type="user",
            device_id="device-note-tests",
            expected_base=snapshot.commit_id,
            operations=(ConfigWrite(text.encode("utf-8")),),
        ))

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.repo), *args], text=True
        ).strip()


def _replace_line(text, key, rendered):
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if line.split("=", 1)[0].strip() == key:
            lines[index] = rendered
            return "\n".join(lines) + "\n"
    lines.append(rendered)
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    unittest.main()
