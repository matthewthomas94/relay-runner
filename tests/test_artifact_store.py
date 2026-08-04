import hashlib
import json
import os
import subprocess
import tempfile
import threading
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from services.artifact_store import (
    ARTIFACT_REF,
    ArchiveIndexWrite,
    ArtifactConcurrentUpdate,
    ArtifactEventCollision,
    ArtifactIdentityError,
    ArtifactInjectedFailure,
    ArtifactMaterializationConflict,
    ArtifactMutation,
    ArtifactStore,
    ArtifactStoreDisabled,
    ArtifactValidationError,
    AttachmentWrite,
    ProgramEventWrite,
    TicketWrite,
)


class ArtifactStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-artifact-tests-")
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.state = self.root / "state"
        self.repo.mkdir()
        self.git("init", "--initial-branch=main", "--quiet")
        (self.repo / "source.txt").write_text("source\n", encoding="utf-8")
        self.git("add", "source.txt")
        self.git(
            "-c",
            "user.name=Relay Tests",
            "-c",
            "user.email=relay-tests@example.invalid",
            "commit",
            "-q",
            "-m",
            "source root",
        )
        self.store = self.make_store()

    def tearDown(self):
        self.temporary.cleanup()

    def make_store(self, **kwargs):
        return ArtifactStore(
            self.repo,
            "project-001",
            self.state,
            enabled=True,
            **kwargs,
        )

    def initialize(self):
        return self.store.initialize(device_id="device-001")

    def mutation(self, event_id, *operations, expected_base=None, provider="codex"):
        return ArtifactMutation(
            event_id=event_id,
            actor_type="pm",
            device_id="device-001",
            provider=provider,
            expected_base=expected_base,
            operations=tuple(operations),
            summary=f"Apply {event_id}",
        )

    def test_store_is_per_project_opt_in_and_initializes_orphan_without_source_files(self):
        disabled = ArtifactStore(self.repo, "project-001", self.state, enabled=False)
        with self.assertRaises(ArtifactStoreDisabled):
            disabled.initialize(device_id="device-001")

        before = self.source_snapshot()
        result = self.initialize()
        after = self.source_snapshot()

        self.assertFalse(result.idempotent)
        self.assertEqual(before, after)
        self.assertEqual(self.git("symbolic-ref", "--short", "HEAD"), "main")
        self.assertEqual(len(self.git("rev-list", "--parents", "-n", "1", ARTIFACT_REF).split()), 1)
        tree_paths = self.git("ls-tree", "-r", "--name-only", ARTIFACT_REF).splitlines()
        self.assertEqual(tree_paths, [".orchestrator/config.toml"])
        self.assertNotIn("source.txt", tree_paths)
        config = (self.repo / ".orchestrator/config.toml").read_text(encoding="utf-8")
        self.assertIn('project_id = "project-001"', config)
        self.assertIn('remote_sync = "local_only"', config)
        exclude = Path(self.git("rev-parse", "--git-path", "info/exclude"))
        if not exclude.is_absolute():
            exclude = self.repo / exclude
        self.assertIn("/.orchestrator/", exclude.read_text(encoding="utf-8").splitlines())
        message = self.git("show", "-s", "--format=%B", ARTIFACT_REF)
        self.assertIn("Relay-Project-ID: project-001", message)
        self.assertIn("Relay-Event-ID: initialize:project-001", message)
        self.assertIn("Relay-Device-ID: device-001", message)
        self.assertIn("Relay-Actor-Type: system", message)

    def test_adoption_rejects_source_parent_symlink_and_foreign_identity(self):
        config = (
            'schema_version = 2\nproject_id = "project-001"\n'
            'prefix = "RR"\nartifact_ref = "refs/heads/relay/artifacts"\n'
            'remote_sync = "local_only"\nnext_id = 1\n'
        ).encode()
        tree = self.private_tree({".orchestrator/config.toml": ("100644", config)})
        source_parent = self.git_with_input(
            b"bad source parent\n", "commit-tree", tree, "-p", self.git("rev-parse", "HEAD")
        )
        self.git("update-ref", ARTIFACT_REF, source_parent)
        with self.assertRaises(ArtifactValidationError):
            self.store.initialize(device_id="device-001")

        self.git("update-ref", "-d", ARTIFACT_REF)
        symlink_tree = self.private_tree(
            {
                ".orchestrator/config.toml": ("100644", config),
                ".orchestrator/RR-1.md": ("120000", b"../../source.txt"),
            }
        )
        symlink_commit = self.git_with_input(b"bad symlink\n", "commit-tree", symlink_tree)
        self.git("update-ref", ARTIFACT_REF, symlink_commit)
        with self.assertRaisesRegex(ArtifactValidationError, "120000"):
            self.store.initialize(device_id="device-001")

        self.git("update-ref", "-d", ARTIFACT_REF)
        gitlink_tree = self.private_tree(
            {
                ".orchestrator/config.toml": ("100644", config),
                ".orchestrator/RR-1.md": ("160000", self.git("rev-parse", "HEAD").encode()),
            }
        )
        gitlink_commit = self.git_with_input(b"bad gitlink\n", "commit-tree", gitlink_tree)
        self.git("update-ref", ARTIFACT_REF, gitlink_commit)
        with self.assertRaisesRegex(ArtifactValidationError, "160000"):
            self.store.initialize(device_id="device-001")

        self.git("update-ref", "-d", ARTIFACT_REF)
        foreign = config.replace(b"project-001", b"project-999")
        foreign_tree = self.private_tree({".orchestrator/config.toml": ("100644", foreign)})
        foreign_commit = self.git_with_input(b"foreign\n", "commit-tree", foreign_tree)
        self.git("update-ref", ARTIFACT_REF, foreign_commit)
        with self.assertRaisesRegex(ArtifactIdentityError, "belongs to project"):
            self.store.initialize(device_id="device-001")

    def test_typed_mutation_materializes_exact_tree_and_is_provider_neutral_and_idempotent(self):
        base = self.initialize().commit_id
        ticket = self.ticket_bytes("RR-1", "First")
        png = b"\x89PNG\r\n\x1a\n" + b"fixture"
        program = json.dumps(
            {
                "event_id": "program-001",
                "project_id": "project-001",
                "kind": "decision",
                "summary": "Use the artifact ref",
            }
        ).encode()
        mutation = self.mutation(
            "event-001",
            TicketWrite("RR-1", "artifact-0001", ticket),
            AttachmentWrite("RR-1", "design.png", "image/png", png),
            ProgramEventWrite("program-001", program),
            expected_base=base,
        )

        result = self.store.mutate(mutation)

        self.assertFalse(result.idempotent)
        self.assertEqual(result.base_commit, base)
        materialized = self.repo / ".orchestrator"
        stored_ticket = (materialized / "RR-1.md").read_text(encoding="utf-8")
        self.assertIn("artifact_id: artifact-0001", stored_ticket)
        self.assertEqual((materialized / "attachments/RR-1/design.png").read_bytes(), png)
        canonical_program = (materialized / "program/events/program-001.json").read_text()
        self.assertEqual(json.loads(canonical_program)["kind"], "decision")
        self.assertEqual(
            self.store.snapshot(provider="codex").files,
            self.store.snapshot(provider="claude").files,
        )

        retry = self.store.mutate(mutation)
        self.assertTrue(retry.idempotent)
        self.assertEqual(retry.commit_id, result.commit_id)
        self.assertEqual(self.git("rev-list", "--count", ARTIFACT_REF), "2")

        changed = self.mutation(
            "event-001",
            TicketWrite("RR-1", "artifact-0001", self.ticket_bytes("RR-1", "Changed")),
            expected_base=base,
        )
        with self.assertRaises(ArtifactEventCollision):
            self.store.mutate(changed)

    def test_security_allowlist_rejects_traversal_cross_ticket_raw_audio_secrets_and_traces(self):
        base = self.initialize().commit_id
        bad_cases = [
            AttachmentWrite("RR-1", "../escape.png", "image/png", b"\x89PNG\r\n\x1a\n"),
            AttachmentWrite("RR-1", "voice.wav", "audio/wav", b"RIFFraw audio"),
            AttachmentWrite("RR-1", "fake.png", "image/png", b"not a png"),
            TicketWrite(
                "RR-1",
                "artifact-0001",
                self.ticket_bytes("RR-1", "Secret", body="api_key = sk-abcdefghijklmnopqrstuvwxyz"),
            ),
            TicketWrite(
                "RR-1",
                "artifact-0001",
                self.ticket_bytes("RR-1", "Trace", body="raw_transcript: private speech"),
            ),
            ProgramEventWrite(
                "program-raw",
                json.dumps(
                    {
                        "event_id": "program-raw",
                        "project_id": "project-001",
                        "raw_transcript": "private speech",
                    }
                ).encode(),
            ),
        ]
        for index, operation in enumerate(bad_cases):
            with self.subTest(operation=type(operation).__name__, index=index):
                with self.assertRaises(ArtifactValidationError):
                    self.store.mutate(
                        self.mutation(f"bad-{index}", operation, expected_base=base)
                    )
        self.assertEqual(self.git("rev-parse", ARTIFACT_REF), base)

        # Ownership is structural: the caller supplies RR-1 and cannot smuggle
        # RR-2 into a path-bearing filename.
        with self.assertRaises(ArtifactValidationError):
            self.store.mutate(
                self.mutation(
                    "bad-owner",
                    AttachmentWrite(
                        "RR-1",
                        "RR-2/other.png",
                        "image/png",
                        b"\x89PNG\r\n\x1a\n",
                    ),
                    expected_base=base,
                )
            )

    def test_limits_and_project_warning_are_actionable(self):
        base = self.initialize().commit_id
        tiny_budget_store = self.make_store(project_warning_bytes=1)
        result = tiny_budget_store.mutate(
            self.mutation(
                "warning-001",
                AttachmentWrite(
                    "RR-1",
                    "small.png",
                    "image/png",
                    b"\x89PNG\r\n\x1a\nfixture",
                ),
                expected_base=base,
            )
        )
        self.assertIn("warning budget", result.warnings[0])

        current = result.commit_id
        oversized = b"\x89PNG\r\n\x1a\n" + b"x" * (10 * 1024 * 1024)
        with self.assertRaisesRegex(ArtifactValidationError, "limit"):
            tiny_budget_store.mutate(
                self.mutation(
                    "oversized-001",
                    AttachmentWrite("RR-1", "large.png", "image/png", oversized),
                    expected_base=current,
                )
            )

        with patch("services.artifact_store.ATTACHMENT_TICKET_MAX_BYTES", 20):
            first = tiny_budget_store.mutate(
                self.mutation(
                    "aggregate-first",
                    AttachmentWrite(
                        "RR-2", "one.png", "image/png", b"\x89PNG\r\n\x1a\n12345"
                    ),
                    expected_base=current,
                )
            )
            with self.assertRaisesRegex(ArtifactValidationError, "attachments for RR-2 total"):
                tiny_budget_store.mutate(
                    self.mutation(
                        "aggregate-second",
                        AttachmentWrite(
                            "RR-2", "two.png", "image/png", b"\x89PNG\r\n\x1a\n67890"
                        ),
                        expected_base=first.commit_id,
                    )
                )

    def test_cas_rejects_stale_base_without_lost_update(self):
        base = self.initialize().commit_id
        first = self.store.mutate(
            self.mutation(
                "event-first",
                TicketWrite("RR-1", "artifact-0001", self.ticket_bytes("RR-1", "First")),
                expected_base=base,
            )
        )
        with self.assertRaises(ArtifactConcurrentUpdate):
            self.make_store().mutate(
                self.mutation(
                    "event-stale",
                    TicketWrite("RR-2", "artifact-0002", self.ticket_bytes("RR-2", "Stale")),
                    expected_base=base,
                )
            )
        self.assertEqual(self.git("rev-parse", ARTIFACT_REF), first.commit_id)
        self.assertFalse((self.repo / ".orchestrator/RR-2.md").exists())

    def test_failure_injection_is_recoverable_and_retry_is_idempotent(self):
        base = self.initialize().commit_id
        operation = TicketWrite(
            "RR-1", "artifact-0001", self.ticket_bytes("RR-1", "Failure recovery")
        )

        for stage in ("before_commit", "during_cas"):
            with self.subTest(stage=stage):
                failing = self.make_store(failure_injector=self.inject_at(stage))
                with self.assertRaises(ArtifactInjectedFailure):
                    failing.mutate(
                        self.mutation(f"failure-{stage}", operation, expected_base=base)
                    )
                self.assertEqual(self.git("rev-parse", ARTIFACT_REF), base)
                self.assertFalse((self.repo / ".orchestrator/RR-1.md").exists())

        after_ref_mutation = self.mutation("failure-after-ref", operation, expected_base=base)
        failing = self.make_store(failure_injector=self.inject_at("after_ref_update"))
        with self.assertRaises(ArtifactInjectedFailure):
            failing.mutate(after_ref_mutation)
        advanced = self.git("rev-parse", ARTIFACT_REF)
        self.assertNotEqual(advanced, base)
        self.assertFalse((self.repo / ".orchestrator/RR-1.md").exists())
        retry = self.make_store().mutate(after_ref_mutation)
        self.assertTrue(retry.idempotent)
        self.assertEqual(retry.commit_id, advanced)
        self.assertTrue((self.repo / ".orchestrator/RR-1.md").exists())

        current = advanced
        second = TicketWrite(
            "RR-2", "artifact-0002", self.ticket_bytes("RR-2", "Materialize recovery")
        )
        during_materialization = self.mutation(
            "failure-materialize", second, expected_base=current
        )
        failing = self.make_store(failure_injector=self.inject_at("during_materialization"))
        with self.assertRaises(ArtifactInjectedFailure):
            failing.mutate(during_materialization)
        materialized_head = self.git("rev-parse", ARTIFACT_REF)
        self.assertFalse((self.repo / ".orchestrator/RR-2.md").exists())
        recovered = self.make_store().recover()
        self.assertEqual(recovered, materialized_head)
        self.assertTrue((self.repo / ".orchestrator/RR-2.md").exists())

    def test_manual_edit_and_ref_divergence_fail_closed(self):
        base = self.initialize().commit_id
        (self.repo / ".orchestrator/config.toml").write_text("manual\n", encoding="utf-8")
        with self.assertRaisesRegex(ArtifactMaterializationConflict, "edited manually"):
            self.store.mutate(
                self.mutation(
                    "manual-edit",
                    TicketWrite("RR-1", "artifact-0001", self.ticket_bytes("RR-1", "Manual")),
                    expected_base=base,
                )
            )
        self.assertEqual(self.git("rev-parse", ARTIFACT_REF), base)

        # Restore, then change both the projection and ref from the recorded base.
        self.store.recover()
        (self.repo / ".orchestrator/config.toml").write_text("manual again\n", encoding="utf-8")
        new_tree = self.git("rev-parse", f"{base}^{{tree}}")
        new_commit = self.git_with_input(
            b"external artifact advance\n",
            "commit-tree",
            new_tree,
            "-p",
            base,
        )
        self.git("update-ref", ARTIFACT_REF, new_commit, base)
        with self.assertRaisesRegex(ArtifactMaterializationConflict, "both changed"):
            self.store.mutate(
                self.mutation(
                    "double-divergence",
                    TicketWrite("RR-2", "artifact-0002", self.ticket_bytes("RR-2", "Both")),
                    expected_base=new_commit,
                )
            )

    def test_dirty_staged_untracked_detached_and_local_ahead_source_state_is_unchanged(self):
        remote = self.root / "source-remote.git"
        subprocess.run(
            ["git", "init", "--bare", "--quiet", str(remote)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.git("remote", "add", "origin", str(remote))
        self.git("push", "-q", "-u", "origin", "main")
        (self.repo / "ahead.txt").write_text("local ahead\n", encoding="utf-8")
        self.git("add", "ahead.txt")
        self.git(
            "-c",
            "user.name=Relay Tests",
            "-c",
            "user.email=relay-tests@example.invalid",
            "commit",
            "-q",
            "-m",
            "local ahead",
        )
        (self.repo / "source.txt").write_text("unstaged\n", encoding="utf-8")
        (self.repo / "staged.txt").write_text("staged\n", encoding="utf-8")
        self.git("add", "staged.txt")
        (self.repo / "untracked.txt").write_text("untracked\n", encoding="utf-8")
        self.git("checkout", "--detach", "--quiet")
        before = self.source_snapshot()

        initialized = self.initialize()
        self.store.mutate(
            self.mutation(
                "isolation-001",
                TicketWrite("RR-1", "artifact-0001", self.ticket_bytes("RR-1", "Isolation")),
                expected_base=initialized.commit_id,
                provider="claude",
            )
        )

        self.assertEqual(self.source_snapshot(), before)
        self.assertEqual(self.git("symbolic-ref", "-q", "--short", "HEAD", allow=(0, 1)), "")

    def test_serialized_writers_commit_each_event_once(self):
        base = self.initialize().commit_id
        failures = []

        def write(index):
            try:
                self.make_store().mutate(
                    self.mutation(
                        f"thread-{index}",
                        TicketWrite(
                            f"RR-{index}",
                            f"artifact-{index:04d}",
                            self.ticket_bytes(f"RR-{index}", f"Thread {index}"),
                        ),
                    )
                )
            except Exception as error:  # pragma: no cover - asserted below.
                failures.append(error)

        threads = [threading.Thread(target=write, args=(index,)) for index in range(1, 5)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        self.assertEqual(failures, [])
        self.assertEqual(self.git("rev-list", "--count", f"{base}..{ARTIFACT_REF}"), "4")
        for index in range(1, 5):
            self.assertTrue((self.repo / f".orchestrator/RR-{index}.md").exists())

    def inject_at(self, expected_stage):
        def inject(stage):
            if stage == expected_stage:
                raise ArtifactInjectedFailure(stage)

        return inject

    def ticket_bytes(self, ticket_id, title, body="Body"):
        return (
            f"---\nid: {ticket_id}\ntitle: {title}\nstatus: backlog\n---\n\n"
            f"## Description\n\n{body}\n"
        ).encode()

    def source_snapshot(self):
        index_path = Path(self.git("rev-parse", "--git-path", "index"))
        if not index_path.is_absolute():
            index_path = self.repo / index_path
        files = {}
        for path in sorted(self.repo.rglob("*")):
            if not path.is_file() or ".git" in path.parts or ".orchestrator" in path.parts:
                continue
            files[path.relative_to(self.repo).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
        refs = [
            line
            for line in self.git("show-ref", allow=(0, 1)).splitlines()
            if not line.endswith(f" {ARTIFACT_REF}")
        ]
        return {
            "head": self.git("rev-parse", "HEAD"),
            "branch": self.git("symbolic-ref", "-q", "HEAD", allow=(0, 1)),
            "status": self.git("status", "--porcelain=v1", "--untracked-files=all"),
            "refs": refs,
            "remotes": self.git("remote", "-v"),
            "index": hashlib.sha256(index_path.read_bytes()).hexdigest(),
            "files": files,
        }

    def git(self, *args, allow=(0,)):
        process = subprocess.run(
            ["git", "-C", str(self.repo), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertIn(
            process.returncode,
            allow,
            msg=f"git {' '.join(args)} failed: {process.stderr.decode()}",
        )
        return process.stdout.decode().strip()

    def git_with_input(self, content, *args):
        process = subprocess.run(
            ["git", "-C", str(self.repo), *args],
            input=content,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env={
                **os.environ,
                "GIT_AUTHOR_NAME": "Relay Tests",
                "GIT_AUTHOR_EMAIL": "relay-tests@example.invalid",
                "GIT_COMMITTER_NAME": "Relay Tests",
                "GIT_COMMITTER_EMAIL": "relay-tests@example.invalid",
            },
        )
        self.assertEqual(process.returncode, 0, process.stderr.decode())
        return process.stdout.decode().strip()

    def private_tree(self, files):
        with tempfile.TemporaryDirectory(prefix="relay-test-index-") as directory:
            index = Path(directory) / "index"
            environment = {**os.environ, "GIT_INDEX_FILE": str(index)}
            subprocess.run(
                ["git", "-C", str(self.repo), "read-tree", "--empty"],
                env=environment,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            for path, (mode, content) in files.items():
                if mode == "160000":
                    blob = content.decode()
                else:
                    blob = subprocess.run(
                        ["git", "-C", str(self.repo), "hash-object", "-w", "--stdin"],
                        input=content,
                        check=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    ).stdout.decode().strip()
                subprocess.run(
                    [
                        "git",
                        "-C",
                        str(self.repo),
                        "update-index",
                        "--add",
                        "--cacheinfo",
                        mode,
                        blob,
                        path,
                    ],
                    env=environment,
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
            return subprocess.run(
                ["git", "-C", str(self.repo), "write-tree"],
                env=environment,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            ).stdout.decode().strip()


if __name__ == "__main__":
    unittest.main()
