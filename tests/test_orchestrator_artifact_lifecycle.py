from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ROOT / "services"
sys.path.insert(0, str(SERVICES))

import orchestrator  # noqa: E402
from services.artifact_rollout import (  # noqa: E402
    PROJECT_OPT_IN,
    ArtifactRolloutBlocked,
)
from services.artifact_retention import ArtifactRetentionManager  # noqa: E402
from services.artifact_store import (  # noqa: E402
    ArchiveIndexWrite,
    ArtifactMutation,
    ArtifactStore,
    AttachmentWrite,
    ConfigWrite,
    TicketWrite,
)
from orchestrator import Daemon, Worker  # noqa: E402


UTC = timezone.utc


class OrchestratorArtifactLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-daemon-artifact-")
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "--initial-branch=main", "--quiet")
        self.git("config", "user.name", "Lifecycle Tests")
        self.git("config", "user.email", "lifecycle@example.invalid")
        (self.repo / "source.txt").write_text("base\n", encoding="utf-8")
        self.git("add", "source.txt")
        self.git("commit", "--quiet", "-m", "source base")

        self.state = self.root / "state"
        self.store = ArtifactStore(
            self.repo,
            "daemon-project",
            self.state,
            enabled=True,
        )
        self.store.initialize(device_id="test-device")
        snapshot = self.store.snapshot()
        config = snapshot.files[".orchestrator/config.toml"].decode("utf-8")
        config = config.replace(
            'artifact_lifecycle = "legacy"',
            'artifact_lifecycle = "enabled"',
        )
        self.store.mutate(ArtifactMutation(
            event_id="enable-daemon-lifecycle",
            actor_type="user",
            device_id="test-device",
            expected_base=snapshot.commit_id,
            operations=(ConfigWrite(config.encode("utf-8")),),
        ))
        self.write_ticket("RR-1")

        self.registry_updated = "2026-08-04T05:00:00Z"
        registry = self.state / "projects" / "registry-v2.json"
        registry.parent.mkdir(parents=True, exist_ok=True)
        registry.write_text(json.dumps({
            "schema_version": 2,
            "active_project_id": "daemon-project",
            "projects": [{
                "project_id": "daemon-project",
                "display_name": "Daemon project",
                "selected_path": str(self.repo),
                "last_resolved_path": str(self.repo),
                "git_common_directory_fingerprint": "daemon-fingerprint",
                "availability": "available",
                "updated_at": self.registry_updated,
            }],
        }), encoding="utf-8")

        config = {
            "orchestrator": {
                "workspace_root": str(self.root / "workspaces"),
                "branch_prefix": "relay/",
                "default_workflow_path": str(SERVICES / "orchestrator_workflow.md"),
                "agent": "codex",
                "command": "/usr/bin/true",
                "max_concurrent_workers": 0,
            },
            "general": {},
        }
        with (
            patch.object(orchestrator, "_data_root", return_value=self.state),
            patch.object(
                orchestrator,
                "_program_registry_path",
                return_value=self.state / "program" / "projects.json",
            ),
        ):
            self.daemon = Daemon(config)
        self.daemon.config_loader = lambda: config
        self.daemon.note_metadata = Mock()

    def tearDown(self):
        for worker in list(self.daemon._workers.values()):
            worker.cancel()
        self.temporary.cleanup()

    def test_artifact_spike_dispatch_is_branchless_and_materializes_immutable_inputs(self):
        self.write_ticket("RR-done", status="done")
        self.write_ticket("RR-spike", execution_mode="spike", depends_on=("RR-done",))
        self.store.mutate(ArtifactMutation(
            event_id="spike-input", actor_type="pm", device_id="test-device",
            expected_base=self.store._head(),
            operations=(AttachmentWrite("RR-spike", "input.png", "image/png", b"\x89PNG\r\n\x1a\nspike-input"),),
        ))
        before = self.git("rev-parse", "HEAD")
        branches = self.git("branch", "--format=%(refname)")
        with patch.object(Worker, "start"):
            run = self.daemon.dispatch(
                ticket_id="RR-spike", repo_path=str(self.repo),
                project_scope_token=self.scope_token(),
            )["run"]
        workspace = Path(run["workspace_path"])
        self.addCleanup(orchestrator.remove_spike_workspace, workspace)
        self.assertEqual(run["branch"], "")
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assertEqual(self.git("branch", "--format=%(refname)"), branches)
        self.assertEqual(self.git("-C", str(workspace), "branch", "--show-current"), "")
        self.assertEqual(self.git("-C", str(workspace), "remote"), "")
        manifest = json.loads((workspace / ".orchestrator/.artifact-snapshot.json").read_text())
        self.assertEqual(manifest["run_id"], run["id"])
        self.assertEqual(manifest["source_start_head"], before)
        self.assertEqual(set(manifest["files"]), {
            ".orchestrator/RR-spike.md",
            ".orchestrator/attachments/RR-spike/input.png",
            ".orchestrator/dependencies/RR-done.json",
        })
        self.assertEqual(workspace.stat().st_mode & 0o222, 0)
        self.assertEqual((workspace / "source.txt").stat().st_mode & 0o222, 0)
        self.assertEqual((workspace / ".orchestrator/RR-spike.md").stat().st_mode & 0o222, 0)
        self.assertIn(
            f"run_id: {run['id']}",
            self.store.snapshot().files[".orchestrator/RR-spike.md"].decode(),
        )

    def test_artifact_spike_terminal_reports_share_provider_contract_and_skip_review(self):
        before = self.git("rev-parse", "HEAD")
        for provider, conclusion in (
            ("codex", "No-go: the proposed approach is unsupported."),
            ("claude", "Further evidence is required before implementation."),
        ):
            with self.subTest(provider=provider):
                ticket_id = f"RR-{provider}"
                run = self.dispatch_spike(ticket_id, provider=provider)
                self.write_ticket(f"RR-{provider}-dependent", status="backlog", depends_on=(ticket_id,))
                result = self.spike_result(conclusion)
                early = self.spike_event(provider, self.spike_result("Preliminary finding."))
                final = self.spike_event(provider, result)
                worker = self.daemon._workers[run["id"]]
                environment = worker.run.get("spike_git_environment") or {}
                if provider == "codex":
                    self.assertIn("RELAY_SPIKE_GIT", environment)
                    self.assertIn(environment["RELAY_SPIKE_GIT"], worker.prompt)
                else:
                    self.assertEqual(environment, {})
                    self.assertIn("Read, Glob, Grep, WebSearch, and WebFetch", worker.prompt)
                command = [sys.executable, "-c", (
                    f"import os; expected = {environment!r}; "
                    "assert all(os.environ.get(k) == v for k, v in expected.items()); "
                    f"print({early!r}); print({final!r})"
                )]
                with patch.object(worker, "_command", return_value=command), \
                        patch.object(self.daemon, "dispatch_review_worker") as review:
                    worker._run()
                    head = self.store._head()
                    ended_at = self.daemon.runs.get(run["id"])["ended_at"]
                    self.daemon._on_worker_complete(run["id"])
                review.assert_not_called()
                self.assertEqual(self.store._head(), head)
                self.assertEqual(self.daemon.runs.get(run["id"])["state"], "SpikeCompleted")
                self.assertEqual(self.daemon.runs.get(run["id"])["ended_at"], ended_at)
                content = self.store.snapshot().files[f".orchestrator/{ticket_id}.md"]
                self.assertEqual((self.repo / f".orchestrator/{ticket_id}.md").read_bytes(), content)
                self.assertIn(conclusion, content.decode())
                self.assertNotIn("Preliminary finding", content.decode())
                self.assertIn("status: done", content.decode())
                self.assertIn(f"run_id: {run['id']}", content.decode())
                self.assertIn("run_state: spike_completed", content.decode())
                self.assertEqual(content.decode().count("## Spike report"), 1)
                self.assertEqual(content.decode().count(f"**Run {run['id']}**"), 1)
                self.assertFalse(Path(run["workspace_path"]).exists())
                lifecycle = self.daemon._artifact_lifecycle(str(self.repo))
                self.assertEqual(lifecycle.leases.active(), ())
                lifecycle.promote_unblocked_dependents()
                self.assertIn("status: backlog", (self.repo / f".orchestrator/RR-{provider}-dependent.md").read_text())
        self.assertEqual(self.git("rev-parse", "HEAD"), before)

    def test_artifact_spike_git_preflight_failure_never_starts_worker(self):
        self.write_ticket("RR-preflight", execution_mode="spike")
        before = self.git("rev-parse", "HEAD")
        with patch.object(Worker, "start") as start, patch.object(
            orchestrator, "prepare_spike_git_environment",
            side_effect=RuntimeError("no read-only-compatible Git; repair Command Line Tools and retry"),
        ):
            with self.assertRaisesRegex(RuntimeError, "spike launch preparation failed.*repair Command Line Tools"):
                self.daemon.dispatch(
                    ticket_id="RR-preflight", repo_path=str(self.repo),
                    project_scope_token=self.scope_token(),
                )
        start.assert_not_called()
        run = self.daemon.runs.list()[0]
        self.assertEqual(run["state"], "Failed")
        self.assertEqual(run["branch"], "")
        self.assertFalse(Path(run["workspace_path"]).exists())
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        ticket = self.store.snapshot().files[".orchestrator/RR-preflight.md"].decode()
        self.assertIn("status: backlog", ticket)
        self.assertIn("repair Command Line Tools", ticket)
        self.assertNotIn("## Spike report", ticket)
        self.assertEqual(self.daemon._artifact_lifecycle(str(self.repo)).leases.active(), ())

    def test_claude_spike_does_not_require_shell_git_preflight(self):
        with patch.object(orchestrator, "prepare_spike_git_environment") as preflight:
            run = self.dispatch_spike("RR-claude-files", provider="claude")
        preflight.assert_not_called()
        worker = self.daemon._workers[run["id"]]
        self.assertIsNone(worker.run["spike_git_environment"])
        self.assertIn("Read,Glob,Grep,WebSearch,WebFetch", worker._command())
        self.assertIn("no shell or Git command tool", worker.prompt)

    def test_artifact_spike_restart_recovers_before_and_after_canonical_publication(self):
        for published in (False, True):
            with self.subTest(published=published):
                run = self.dispatch_spike(f"RR-recovery-{published}")
                self.ready_spike(run)
                if published:
                    self.daemon._spike_ticket_update(run, result=self.spike_result())
                    # Even if local evidence is gone, canonical publication is authoritative.
                    orchestrator.remove_spike_workspace(Path(run["workspace_path"]))
                    Path(run["log_path"]).unlink()
                self.daemon._workers.pop(run["id"])
                self.assertEqual(self.daemon.runs.reconcile_on_startup(), 1)
                self.daemon._artifact_lifecycles.clear()
                self.daemon._recover_stalled_spikes()
                head = self.store._head()
                self.daemon._recover_stalled_spikes()
                self.daemon._on_worker_complete(run["id"])
                self.assertEqual(self.store._head(), head)
                self.assertEqual(self.daemon.runs.get(run["id"])["state"], "SpikeCompleted")
                content = (self.repo / f".orchestrator/{run['ticket_id']}.md").read_text()
                self.assertIn("status: done", content)
                self.assertIn(f"run_id: {run['id']}", content)
                self.assertEqual(content.count("## Spike report"), 1)

    def test_artifact_spike_concurrent_duplicate_completion_is_idempotent(self):
        run = self.dispatch_spike("RR-duplicate")
        self.ready_spike(run)
        with ThreadPoolExecutor(max_workers=2) as executor:
            deliveries = [executor.submit(self.daemon._on_worker_complete, run["id"]) for _ in range(2)]
            for delivery in deliveries:
                delivery.result(timeout=30)
        self.assertEqual(self.daemon.runs.get(run["id"])["state"], "SpikeCompleted")
        content = (self.repo / ".orchestrator/RR-duplicate.md").read_text()
        self.assertEqual(content.count("## Spike report"), 1)
        self.assertEqual(content.count(f"**Run {run['id']}**"), 1)
        self.assertIn(f"run_id: {run['id']}", content)

    def test_artifact_spike_concurrent_edit_preserves_evidence_until_reconciliation(self):
        run = self.dispatch_spike("RR-race")
        self.ready_spike(run)
        lifecycle = self.daemon._artifact_lifecycle(str(self.repo))
        mutate = lifecycle.store.mutate

        def concurrent_edit(mutation):
            if mutation.event_id.endswith(":spike"):
                self.edit_ticket("RR-race", "concurrent-pm-edit", lambda text: text + "\n## PM note\n\nRetain this decision.\n")
            return mutate(mutation)

        with patch.object(lifecycle.store, "mutate", side_effect=concurrent_edit):
            self.daemon._on_worker_complete(run["id"])
        pending = self.daemon.runs.get(run["id"])
        self.assertEqual(pending["state"], "SpikeResultReady")
        self.assertIn("artifact base changed", pending["last_error"])
        self.assertTrue(Path(run["workspace_path"]).exists())
        self.assertEqual(len(lifecycle.leases.active()), 1)
        self.assertNotIn("## Spike report", (self.repo / ".orchestrator/RR-race.md").read_text())
        self.daemon.runs.reconcile_on_startup()
        self.daemon._recover_stalled_spikes()
        self.assertEqual(self.daemon.runs.get(run["id"])["state"], "SpikeCompleted")
        content = (self.repo / ".orchestrator/RR-race.md").read_text()
        self.assertIn("Retain this decision.", content)
        self.assertIn("## Spike report", content)

    def test_artifact_spike_publication_recovers_artifact_writer_interruptions(self):
        for stage in ("before_commit", "after_ref_update", "during_materialization"):
            with self.subTest(stage=stage):
                run = self.dispatch_spike(f"RR-{stage}")
                self.ready_spike(run)
                lifecycle = self.daemon._artifact_lifecycle(str(self.repo))

                def interrupt(current):
                    if current == stage:
                        raise RuntimeError(f"Interrupted {stage}")

                with patch.object(lifecycle.store, "failure_injector", interrupt):
                    self.daemon._on_worker_complete(run["id"])
                self.assertEqual(self.daemon.runs.get(run["id"])["state"], "SpikeResultReady")
                self.assertTrue(Path(run["workspace_path"]).exists())
                self.daemon.runs.reconcile_on_startup()
                self.daemon._artifact_lifecycles.clear()
                self.daemon._recover_stalled_spikes()
                self.assertEqual(self.daemon.runs.get(run["id"])["state"], "SpikeCompleted")
                content = self.store.snapshot().files[f".orchestrator/{run['ticket_id']}.md"]
                self.assertEqual((self.repo / f".orchestrator/{run['ticket_id']}.md").read_bytes(), content)
                self.assertEqual(content.decode().count("## Spike report"), 1)

    def test_artifact_spike_invalid_terminal_results_and_worker_failures_do_not_complete(self):
        cases = (
            ("missing", [], 0, "no structured spike result"),
            ("malformed", [self.spike_event("codex", self.spike_result()), "{\"type\":\"result\",\"result\":\"invalid\"}"], 0, "not valid JSON"),
            ("crashed", [self.spike_event("claude", self.spike_result())], 1, "exited with status 1"),
            ("mutation", [json.dumps({"type": "item.started", "item": {"id": "tool-1", "type": "command_execution", "command": "touch source.txt"}}), self.spike_event("codex", self.spike_result())], 0, "mutating command"),
        )
        for name, events, exit_code, diagnostic in cases:
            with self.subTest(case=name):
                run = self.dispatch_spike(f"RR-{name}")
                worker = self.daemon._workers[run["id"]]
                script = f"import sys; print({chr(10).join(events)!r}); sys.exit({exit_code})"
                with patch.object(worker, "_command", return_value=[sys.executable, "-c", script]):
                    worker._run()
                failed = self.daemon.runs.get(run["id"])
                self.assertEqual(failed["state"], "Failed")
                self.assertIn(diagnostic, failed["last_error"])
                content = (self.repo / f".orchestrator/{run['ticket_id']}.md").read_text()
                self.assertIn("status: backlog", content)
                self.assertNotIn("## Spike report", content)
                self.assertNotIn("structured_output", content)
                self.assertFalse(Path(run["workspace_path"]).exists())

    def test_artifact_spike_failure_publication_recovers_without_a_new_active_run(self):
        for state in ("Failed", "Canceled"):
            with self.subTest(state=state):
                run = self.dispatch_spike(f"RR-interrupted-{state}")
                self.daemon.runs.update(run["id"], state=state, last_error="Investigation stopped.", ended=True)
                lifecycle = self.daemon._artifact_lifecycle(str(self.repo))

                def interrupt(stage):
                    if stage == "after_ref_update":
                        raise RuntimeError("Interrupted failure publication")

                with patch.object(lifecycle.store, "failure_injector", interrupt):
                    self.daemon._on_worker_complete(run["id"])
                pending = self.daemon.runs.get(run["id"])
                self.assertEqual(pending["state"], state)
                self.assertEqual(pending["last_error"], "Investigation stopped.")
                self.assertIn("publication pending", pending["activity"])
                head = self.store._head()
                self.daemon._workers.pop(run["id"], None)
                self.assertEqual(self.recover_spikes_after_restart(), 0)
                self.assertEqual(self.daemon.runs.get(run["id"])["state"], state)
                self.assertEqual(self.daemon.runs.get(run["id"])["last_error"], "Investigation stopped.")
                self.assertEqual(self.store._head(), head)
                content = (self.repo / f".orchestrator/{run['ticket_id']}.md").read_text()
                self.assertIn("status: backlog", content)
                self.assertIn(f"run_state: {state.lower()}", content)
                self.assertNotIn("## Spike report", content)
                self.assertFalse(Path(run["workspace_path"]).exists())

    def test_artifact_spike_restart_publishes_terminal_worker_outcomes_before_releasing_leases(self):
        for provider in ("codex", "claude"):
            for state in ("Failed", "Canceled"):
                with self.subTest(provider=provider, state=state):
                    run = self.dispatch_spike(f"RR-terminal-{provider}-{state}", provider=provider)
                    self.daemon._workers.pop(run["id"])
                    reason = f"Investigation {state.lower()} before the completion callback."
                    self.daemon.runs.update(run["id"], state=state, last_error=reason, ended=True)
                    ended_at = self.daemon.runs.get(run["id"])["ended_at"]

                    with patch.object(self.daemon, "dispatch_review_worker") as review:
                        self.assertEqual(self.recover_spikes_after_restart(), 0)
                    review.assert_not_called()
                    recovered = self.daemon.runs.get(run["id"])
                    self.assertEqual(recovered["state"], state)
                    self.assertEqual(recovered["last_error"], reason)
                    self.assertEqual(recovered["ended_at"], ended_at)
                    content = self.store.snapshot().files[f".orchestrator/{run['ticket_id']}.md"]
                    self.assertEqual((self.repo / f".orchestrator/{run['ticket_id']}.md").read_bytes(), content)
                    self.assertIn(b"status: backlog", content)
                    self.assertIn(f"run_state: {state.lower()}".encode(), content)
                    self.assertIn(b"run_id: null", content)
                    self.assertIn(reason.encode(), content)
                    self.assertEqual(content.count(f"**Run {run['id']}**".encode()), 1)
                    self.assertNotIn(b"## Spike report", content)
                    self.assertFalse(Path(run["workspace_path"]).exists())
                    lifecycle = self.daemon._artifact_lifecycle(str(self.repo))
                    self.assertEqual(lifecycle.leases.active(), ())

                    head = self.store._head()
                    self.recover_spikes_after_restart()
                    self.daemon._on_worker_complete(run["id"])
                    self.assertEqual(self.store._head(), head)
                    self.assertEqual(self.daemon.runs.get(run["id"])["last_error"], reason)

    def test_artifact_spike_restart_preserves_unrelated_snapshot_leases(self):
        run = self.dispatch_spike("RR-terminal-lease")
        self.daemon._workers.pop(run["id"])
        self.daemon.runs.update(run["id"], state="Failed", last_error="Investigation stopped.", ended=True)
        lifecycle = self.daemon._artifact_lifecycle(str(self.repo))
        external_lease = lifecycle.leases.acquire(
            lease_id="external-reader", ticket_id="RR-1", artifact_id="artifact-RR-1",
            artifact_head=self.store._head(), run_id="external-reader", role="reviewer",
            provider="codex",
        )
        self.recover_spikes_after_restart()
        self.assertEqual(lifecycle.leases.active(), (external_lease,))
        content = self.store.snapshot().files[".orchestrator/RR-terminal-lease.md"]
        self.assertIn(b"run_state: failed", content)
        self.assertFalse(Path(run["workspace_path"]).exists())

    def test_artifact_spike_precommit_failure_preserves_terminal_intent_and_diagnostic(self):
        for provider in ("codex", "claude"):
            for state in ("Failed", "Canceled"):
                with self.subTest(provider=provider, state=state):
                    run = self.dispatch_spike(f"RR-pending-{provider}-{state}", provider=provider)
                    self.daemon._workers.pop(run["id"])
                    reason = "Canceled (no live worker)" if state == "Canceled" else "Investigation failed validation."
                    lifecycle = self.daemon._artifact_lifecycle(str(self.repo))

                    def interrupt(stage):
                        if stage == "before_commit":
                            raise RuntimeError("Interrupted terminal publication")

                    with patch.object(ArtifactStore, "_inject", side_effect=interrupt):
                        if state == "Canceled":
                            self.assertTrue(self.daemon.cancel_run(run["id"])["canceled"])
                        else:
                            self.daemon.runs.update(run["id"], state=state, last_error=reason, ended=True)
                            self.daemon._on_worker_complete(run["id"])
                        # A second failed recovery must retain the original outcome and lease.
                        self.assertEqual(self.recover_spikes_after_restart(), 0)
                    pending = self.daemon.runs.get(run["id"])
                    self.assertEqual(pending["state"], state)
                    self.assertEqual(pending["last_error"], reason)
                    self.assertIn("publication pending", pending["activity"])
                    self.assertIn("Interrupted terminal publication", pending["activity"])
                    self.assertEqual(len(lifecycle.leases.active()), 1)
                    self.assertTrue(Path(run["workspace_path"]).exists())
                    self.assertTrue(lifecycle._snapshot_proof_path(run["id"]).exists())
                    content = self.store.snapshot().files[f".orchestrator/{run['ticket_id']}.md"]
                    self.assertIn(b"status: in_progress", content)
                    self.assertIn(f"run_id: {run['id']}".encode(), content)

                    self.edit_ticket(
                        run["ticket_id"], f"pending-note-{run['id']}",
                        lambda text: text + "\n## PM note\n\nRetain the retry decision.\n",
                    )
                    self.assertEqual(self.recover_spikes_after_restart(), 0)
                    recovered = self.daemon.runs.get(run["id"])
                    self.assertEqual(recovered["state"], state)
                    self.assertEqual(recovered["last_error"], reason)
                    self.assertNotIn("publication pending", recovered["activity"])
                    content = self.store.snapshot().files[f".orchestrator/{run['ticket_id']}.md"]
                    self.assertEqual((self.repo / f".orchestrator/{run['ticket_id']}.md").read_bytes(), content)
                    self.assertIn(b"status: backlog", content)
                    self.assertIn(f"run_state: {state.lower()}".encode(), content)
                    self.assertIn(reason.encode(), content)
                    self.assertIn(b"Retain the retry decision.", content)
                    self.assertNotIn(b"Interrupted terminal publication", content)
                    self.assertNotIn(b"## Spike report", content)
                    self.assertEqual(content.count(f"**Run {run['id']}**".encode()), 1)
                    self.assertFalse(Path(run["workspace_path"]).exists())
                    self.assertEqual(lifecycle.leases.active(), ())
                    head = self.store._head()
                    self.recover_spikes_after_restart()
                    self.daemon._on_worker_complete(run["id"])
                    self.assertEqual(self.store._head(), head)
                    self.assertEqual(self.daemon.runs.get(run["id"])["last_error"], reason)

    def test_artifact_spike_completion_does_not_overwrite_reassigned_ticket(self):
        run = self.dispatch_spike("RR-reassigned")
        self.ready_spike(run)
        self.edit_ticket("RR-reassigned", "reassign-run", lambda text: text.replace(f"run_id: {run['id']}", "run_id: 900"))
        head = self.store._head()
        self.daemon._on_worker_complete(run["id"])
        self.assertEqual(self.store._head(), head)
        pending = self.daemon.runs.get(run["id"])
        self.assertEqual(pending["state"], "SpikeResultReady")
        self.assertIn("canonical spike ticket changed", pending["last_error"])
        self.assertNotIn("## Spike report", (self.repo / ".orchestrator/RR-reassigned.md").read_text())

    def test_artifact_spike_snapshot_tampering_cannot_publish_success(self):
        run = self.dispatch_spike("RR-tamper")
        self.ready_spike(run)
        ticket = Path(run["workspace_path"]) / ".orchestrator/RR-tamper.md"
        ticket.chmod(0o644)
        ticket.write_text(ticket.read_text() + "\nModified input.\n")
        self.daemon._on_worker_complete(run["id"])
        pending = self.daemon.runs.get(run["id"])
        self.assertEqual(pending["state"], "SpikeResultReady")
        self.assertIn("immutable worker snapshot file changed", pending["last_error"])
        self.assertNotIn("## Spike report", (self.repo / ".orchestrator/RR-tamper.md").read_text())
        self.assertTrue(Path(run["workspace_path"]).exists())

    def test_artifact_spike_required_inputs_scope_and_command_authorization_are_enforced(self):
        self.write_ticket("RR-inputs", execution_mode="spike")
        self.edit_ticket("RR-inputs", "require-input", lambda text: text + "\n## Required inputs\n\n- [ ] Local evidence\n")
        before = self.store._head()
        with patch.object(Worker, "start") as start:
            with self.assertRaisesRegex(Exception, "confirmed project scope token"):
                self.daemon.dispatch(ticket_id="RR-inputs", repo_path=str(self.repo))
            with self.assertRaisesRegex(ValueError, "Required inputs"):
                self.daemon.dispatch(ticket_id="RR-inputs", repo_path=str(self.repo), project_scope_token=self.scope_token())
            with patch.object(orchestrator, "_relay_command_current", return_value=False), \
                    patch.object(orchestrator, "validate_and_mark_mutation", side_effect=ValueError("outside authorized ticket scope")) as authorize:
                with self.assertRaisesRegex(ValueError, "authorized ticket scope"):
                    self.daemon.dispatch(ticket_id="RR-inputs", repo_path=str(self.repo), project_scope_token=self.scope_token(), relay_command_seq=7, relay_command_id="command-7")
                self.assertEqual(authorize.call_args.args[3]["ticket_id"], "RR-INPUTS")
            start.assert_not_called()
        self.assertEqual(self.store._head(), before)

    def test_artifact_spike_cancellation_is_canonical_and_idempotent(self):
        run = self.dispatch_spike("RR-cancel")
        self.daemon._workers.pop(run["id"])
        self.assertTrue(self.daemon.cancel_run(run["id"])["canceled"])
        head = self.store._head()
        self.daemon._on_worker_complete(run["id"])
        self.assertEqual(self.store._head(), head)
        self.assertEqual(self.daemon.runs.get(run["id"])["state"], "Canceled")
        content = (self.repo / ".orchestrator/RR-cancel.md").read_text()
        self.assertIn("status: backlog", content)
        self.assertIn("run_state: canceled", content)
        self.assertNotIn("## Spike report", content)

    def test_confirmed_dispatch_structured_outcome_and_reviewed_merge_publish_artifact_truth(self):
        with self.assertRaisesRegex(Exception, "confirmed project scope token"):
            self.daemon.dispatch(ticket_id="RR-1", repo_path=str(self.repo))

        with patch.object(Worker, "start", autospec=True):
            dispatched = self.daemon.dispatch(
                ticket_id="RR-1",
                repo_path=str(self.repo),
                project_scope_token=self.scope_token(),
            )

        run = dispatched["run"]
        run_id = int(run["id"])
        workspace = Path(run["workspace_path"])
        self.assertTrue((workspace / ".orchestrator/RR-1.md").is_file())
        self.assertEqual(
            self.git("-C", str(workspace), "ls-files", "--", ".orchestrator"),
            "",
        )
        lifecycle = self.daemon._artifact_lifecycle(str(self.repo))
        self.assertIsNotNone(lifecycle)
        self.assertEqual(
            [lease.lease_id for lease in lifecycle.leases.active()],
            [f"run:{run_id}:worker"],
        )

        (workspace / "source.txt").write_text("implemented\n", encoding="utf-8")
        self.git("-C", str(workspace), "add", "source.txt")
        self.git("-C", str(workspace), "commit", "--quiet", "-m", "implement source")
        source_commit = self.git("-C", str(workspace), "rev-parse", "HEAD")
        accepted = self.daemon.submit_worker_outcome(run_id, {
            "status": "completed",
            "summary": "Implemented the daemon lifecycle fixture.",
            "changed_paths": ["source.txt"],
            "verification": ["focused lifecycle test passed"],
            "source_commit": source_commit,
        })
        self.assertTrue(accepted["accepted"])

        manifest = json.loads(
            (workspace / ".orchestrator/.artifact-snapshot.json").read_text(encoding="utf-8")
        )
        outcome, reason = lifecycle.validate_worker_completion(
            workspace_path=workspace,
            ticket_id="RR-1",
            run_id=run_id,
            provider="codex",
            start_head=manifest["source_start_head"],
        )
        self.assertEqual(outcome, "completed")
        self.assertIn("accepted", reason)
        self.daemon.runs.update(run_id, state="AwaitingReview")
        lifecycle.begin_review(run_id=run_id, provider="claude")
        with self.daemon._workers_lock:
            self.daemon._workers.pop(run_id, None)

        merged = self.daemon.accept_worker_run(run_id)

        self.assertTrue(merged["accepted"])
        self.assertEqual(merged["run"]["state"], "Merged")
        self.assertEqual(lifecycle.leases.active(), ())
        canonical = self.store.snapshot().files[".orchestrator/RR-1.md"].decode("utf-8")
        self.assertIn("status: done", canonical)
        self.assertIn("reviewed source merge", canonical)
        self.assertEqual(self.git("show", "--pretty=", "--name-only", source_commit), "source.txt")
        self.assertNotIn(
            ".orchestrator",
            self.git("ls-tree", "-r", "--name-only", "HEAD"),
        )

    def test_session_capture_requires_same_confirmed_scope_and_publishes_artifact_first(self):
        with self.assertRaisesRegex(Exception, "confirmed project scope token"):
            self.daemon.session_capture(
                repo_path=str(self.repo),
                capture_id="scope-capture",
                provider="codex",
                entries=[{"kind": "decision", "title": "Use confirmed scope"}],
            )

        result = self.daemon.session_capture(
            repo_path=str(self.repo),
            capture_id="scope-capture",
            provider="claude",
            entries=[{"kind": "decision", "title": "Use confirmed scope"}],
            project_scope_token=self.scope_token(),
        )

        self.assertEqual(result["durable_authority"], "relay/artifacts")
        self.assertEqual(result["provider"], "claude")
        event_id = result["artifact_event_ids"][0]
        document = json.loads(
            self.store.snapshot().files[
                f".orchestrator/program/events/{event_id}.json"
            ]
        )
        self.assertEqual(document["project_id"], "daemon-project")
        self.assertEqual(document["provider"], "claude")
        self.assertEqual(document["record_kind"], "decision")
        self.assertEqual(result["counts"], {"Decision": 1})

    def test_rollout_diagnostics_are_bounded_default_off_and_surface_recovery_code(self):
        status = self.daemon.artifact_rollout_status()
        self.assertEqual(status["status"], "available")
        rollout = status["rollout"]
        self.assertEqual(rollout["project_opt_in_count"], 0)
        self.assertFalse(rollout["cohorts"]["new_project_default"]["enabled"])
        self.assertFalse(rollout["cohorts"]["legacy_migration_offer"]["enabled"])
        self.assertNotIn(str(self.repo), json.dumps(status, sort_keys=True))

        rollout_store = self.daemon.artifact_rollout
        rollout_store.rollout_root.mkdir(parents=True, exist_ok=True)
        rollout_store.path.write_text("{broken", encoding="utf-8")
        rollout_store.backup_path.write_text("{also-broken", encoding="utf-8")
        blocked = self.daemon.artifact_rollout_status()
        self.assertEqual(blocked["status"], "verification_blocked")
        self.assertEqual(blocked["error_code"], "rollout_state_corrupt")
        self.assertIn("restore", blocked["recovery"].lower())

    def test_rollout_kill_switch_blocks_cached_configured_writer_without_legacy_fallback(self):
        lifecycle = self.daemon._artifact_lifecycle(str(self.repo))
        self.assertIsNotNone(lifecycle)
        initial = self.daemon.artifact_rollout.decision(
            "daemon-project",
            project_kind="existing",
            configured_opt_in=True,
        )
        self.assertEqual(initial.reason_code, "configured_project_opt_in")
        head_before = self.store._head()

        self.daemon.artifact_rollout.pause_cohort(
            PROJECT_OPT_IN,
            writers_drained=True,
            sync_frozen=True,
            reason_code="verified_writer_failure",
        )
        paused = self.daemon.artifact_rollout.decision(
            "daemon-project",
            project_kind="existing",
            configured_opt_in=True,
        )
        self.assertFalse(paused.artifact_writes_enabled)
        self.assertFalse(paused.artifact_sync_enabled)
        with self.assertRaises(ArtifactRolloutBlocked) as blocked:
            self.daemon.artifact_board_claim_next_id(
                repo_path=str(self.repo),
                project_scope_token=self.scope_token(),
                request_id="paused-board-claim",
            )
        self.assertEqual(blocked.exception.code, "project_opt_in_kill_switch")
        self.assertEqual(self.store._head(), head_before)

        handler = object.__new__(orchestrator.Handler)
        handler.daemon = self.daemon
        with patch.object(orchestrator, "_read_body", return_value={
            "repo_path": str(self.repo),
            "project_scope_token": self.scope_token(),
            "request_id": "paused-http-board-claim",
        }):
            status, payload = handler._route(
                "POST",
                "/v1/artifacts/tickets/claim-next-id",
            )
        self.assertEqual(status, 409)
        self.assertEqual(payload["error_code"], "project_opt_in_kill_switch")
        self.assertIn("drained", payload["recovery"])
        self.assertEqual(self.store._head(), head_before)

        self.daemon.artifact_rollout.resume_cohort(PROJECT_OPT_IN, confirmed=True)
        self.assertIs(self.daemon._artifact_lifecycle(str(self.repo)), lifecycle)

    def test_board_authoring_uses_confirmed_typed_artifact_writer_for_id_ticket_attachment_and_delete(self):
        with self.assertRaisesRegex(Exception, "confirmed project scope token"):
            self.daemon.artifact_board_claim_next_id(
                repo_path=str(self.repo),
                project_scope_token=None,
            )

        claim = self.daemon.artifact_board_claim_next_id(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            request_id="board-claim-test",
        )
        self.assertEqual(claim["ticket_id"], "REP-1")
        markdown = b"""---
id: REP-1
title: Board artifact writer
status: backlog
priority: medium
execution_mode: implementation
depends_on: []
run_id: null
canceled: false
order: 20
---

## Description

Saved through the daemon-owned typed writer.
"""
        saved = self.daemon.artifact_board_write_ticket(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            ticket_id="REP-1",
            markdown_base64=base64.b64encode(markdown).decode("ascii"),
            request_id="board-save-test",
        )
        stored = base64.b64decode(saved["markdown_base64"])
        self.assertIn(b"artifact_id: ticket-", stored)
        self.assertIn(b"user_edited_at:", stored)
        self.assertEqual(
            stored,
            self.store.snapshot().files[".orchestrator/REP-1.md"],
        )

        png = b"\x89PNG\r\n\x1a\nboard-proof"
        self.daemon.artifact_board_write_attachment(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            ticket_id="REP-1",
            filename="proof.png",
            mime_type="image/png",
            content_base64=base64.b64encode(png).decode("ascii"),
            request_id="board-attachment-test",
        )
        self.assertEqual(
            self.store.snapshot().files[".orchestrator/attachments/REP-1/proof.png"],
            png,
        )

        deleted = self.daemon.artifact_board_delete_ticket(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            ticket_id="REP-1",
            request_id="board-delete-test",
        )
        self.assertFalse(deleted["idempotent"])
        snapshot = self.store.snapshot()
        self.assertNotIn(".orchestrator/REP-1.md", snapshot.files)
        self.assertNotIn(".orchestrator/attachments/REP-1/proof.png", snapshot.files)
        history = self.daemon.artifact_history_search(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            query="Board artifact",
        )
        artifact_id = history["history"][0]["artifact_id"]
        detail = self.daemon.artifact_history_detail(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            artifact_id=artifact_id,
        )
        self.assertEqual(detail["availability"], "available")
        self.assertFalse(detail["materialized"])
        restored = self.daemon.artifact_history_restore(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            artifact_id=artifact_id,
            request_id="board-restore-test",
            provider="codex",
        )
        retried = self.daemon.artifact_history_restore(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            artifact_id=artifact_id,
            request_id="board-restore-test",
            provider="claude",
        )
        self.assertEqual(restored["ticket_ids"], ["REP-1"])
        self.assertTrue(retried["idempotent"])
        self.assertIn(".orchestrator/REP-1.md", self.store.snapshot().files)

    def test_global_note_http_contract_needs_no_project_and_preserves_provider_metadata(self):
        from services.global_notes import GlobalNoteLibrary
        self.daemon.global_notes = GlobalNoteLibrary(self.state, "global-test", lambda: [])
        handler = object.__new__(orchestrator.Handler)
        handler.daemon = self.daemon
        payload = {
            "request_id": "global-http", "created_at": "2026-09-20T08:00:00Z",
            "capture_started_at": "2026-09-20T08:00:00Z", "captured_at": "2026-09-20T08:00:05Z",
            "recording_state": "completed", "checkpoint_reason": "complete",
            "capture_ended_at": "2026-09-20T08:00:05Z", "segments": [], "provider": "claude",
        }
        with patch.object(orchestrator, "_read_body", return_value=payload):
            status, created = handler._route("POST", "/v1/artifacts/notes/create")
        self.assertEqual(status, 201)
        identity = created["note"]["identity"]
        self.assertEqual(identity["project_id"], "global-notes")
        self.daemon.note_metadata.schedule.assert_called_once()
        status, catalog = handler._route("GET", "/v1/artifacts/notes")
        self.assertEqual(status, 200)
        self.assertEqual(catalog["total_count"], 1)
        status, detail = handler._route("GET", "/v1/artifacts/notes/" + identity["note_id"])
        self.assertEqual(detail["note"], created["note"])
        with patch.object(orchestrator, "_read_body", return_value={
            "artifact_id": identity["artifact_id"], "request_id": "delete-global"
        }):
            status, deleted = handler._route("POST", "/v1/artifacts/notes/" + identity["note_id"] + "/delete")
        self.assertEqual(status, 200)
        self.assertTrue(deleted["deleted"])
        self.assertEqual(self.daemon.global_notes.list()["notes"], [])

    def test_project_note_http_contract_is_scoped_provider_neutral_and_separate_from_tickets(self):
        payload = {
            "repo_path": str(self.repo),
            "project_scope_token": self.scope_token(),
            "request_id": "note-http-create",
            "created_at": "2026-09-20T08:00:00Z",
            "capture_started_at": "2026-09-20T08:00:00Z",
            "captured_at": "2026-09-20T08:00:05Z",
            "recording_state": "recording",
            "checkpoint_reason": "checkpoint",
            "segments": [{
                "segment_id": "segment-1",
                "captured_at": "2026-09-20T08:00:05Z",
                "text": "Provider-neutral meeting words",
            }],
            "provider": "codex",
        }
        with self.assertRaisesRegex(Exception, "confirmed project scope token"):
            self.daemon.artifact_note_create(**{
                **payload,
                "project_scope_token": None,
            })

        handler = object.__new__(orchestrator.Handler)
        handler.daemon = self.daemon
        with patch.object(orchestrator, "_read_body", return_value=payload):
            status, created = handler._route("POST", "/v1/artifacts/notes/create")
        self.assertEqual(status, 201)
        identity = created["note"]["identity"]
        self.daemon.note_metadata.schedule.assert_called_once()
        self.daemon.note_metadata.schedule.reset_mock()
        with self.assertRaises(Exception):
            self.daemon.artifact_note_create(**{**payload, "segments": [{"text": "unsaved"}]})
        self.daemon.note_metadata.schedule.assert_not_called()
        self.assertEqual(identity["note_id"], "REP-N1")
        self.assertEqual(identity["project_id"], "daemon-project")
        self.assertEqual(created["sync"]["state"], "local_only")

        update = {
            "identity": identity,
            "captured_at": "2026-09-20T08:10:00Z",
            "recording_state": "paused",
            "checkpoint_reason": "pause",
            "segments": payload["segments"],
        }
        updated = self.daemon.artifact_note_update(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            note_id="REP-N1",
            request_id="note-http-pause",
            update=update,
            provider="claude",
        )
        self.assertEqual(updated["note"]["recording_state"], "paused")
        self.daemon.note_metadata.schedule.assert_called_once()
        with patch.object(orchestrator, "_read_body", return_value=payload):
            status, retried_metadata = handler._route("POST", "/v1/artifacts/notes/REP-N1/retry-metadata")
        self.assertEqual(status, 200)
        self.assertEqual(retried_metadata["note"]["metadata"]["state"], "pending")
        retry = self.daemon.artifact_note_update(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            note_id="REP-N1",
            request_id="note-http-pause",
            update=update,
            provider="codex",
        )
        self.assertTrue(retry["idempotent"])

        query = urlencode({
            "repo_path": str(self.repo),
            "project_scope_token": self.scope_token(),
            "limit": 1,
        })
        status, listed = handler._route("GET", f"/v1/artifacts/notes?{query}")
        self.assertEqual(status, 200)
        self.assertEqual([card["note_id"] for card in listed["notes"]], ["REP-N1"])
        self.assertEqual(listed["limit"], 1)
        self.assertFalse(listed["has_more"])
        self.assertEqual(
            listed["notes"][0]["reference"]["path"],
            ".orchestrator/notes/REP-N1.md",
        )
        self.assertEqual(
            orchestrator.tomllib.loads(
                self.store.snapshot().files[".orchestrator/config.toml"].decode()
            )["next_id"],
            1,
        )
        self.assertEqual([ticket["id"] for ticket in orchestrator.scan_repo(self.repo)], ["RR-1"])

    def test_project_note_delete_http_requires_scope_and_removes_note(self):
        created = self.daemon.artifact_note_create(
            repo_path=str(self.repo), project_scope_token=self.scope_token(), request_id="delete-create",
            created_at="2026-09-20T08:00:00Z", capture_started_at="2026-09-20T08:00:00Z",
            captured_at="2026-09-20T08:01:00Z", capture_ended_at="2026-09-20T08:01:00Z",
            recording_state="completed", checkpoint_reason="complete", segments=[],
        )
        identity = created["note"]["identity"]
        handler = object.__new__(orchestrator.Handler)
        handler.daemon = self.daemon
        payload = dict(repo_path=str(self.repo), project_scope_token=None,
                       artifact_id=identity["artifact_id"], request_id="delete-http")
        path = f"/v1/artifacts/notes/{identity['note_id']}/delete"
        with patch.object(orchestrator, "_read_body", return_value=payload):
            status, failure = handler._route("POST", path)
        self.assertEqual(status, 422)
        self.assertIn("confirmed project scope token", failure["error"])
        payload["project_scope_token"] = self.scope_token()
        with patch.object(orchestrator, "_read_body", return_value=payload):
            status, response = handler._route("POST", path)
        self.assertEqual(status, 200)
        self.assertTrue(response["deleted"])
        self.assertEqual(self.daemon.artifact_note_list(
            repo_path=str(self.repo), project_scope_token=self.scope_token())["notes"], [])

    def test_project_note_http_rejects_registry_refreshed_scope_then_reuses_request_with_fresh_scope(self):
        handler = object.__new__(orchestrator.Handler)
        handler.daemon = self.daemon
        create_payload = {
            "repo_path": str(self.repo),
            "project_scope_token": self.scope_token(),
            "request_id": "note-scope-create",
            "created_at": "2026-09-20T08:00:00Z",
            "capture_started_at": "2026-09-20T08:00:00Z",
            "captured_at": "2026-09-20T08:00:05Z",
            "recording_state": "recording",
            "checkpoint_reason": "checkpoint",
            "segments": [],
            "provider": "codex",
        }
        with patch.object(orchestrator, "_read_body", return_value=create_payload):
            status, created = handler._route("POST", "/v1/artifacts/notes/create")
        self.assertEqual(status, 201)

        stale_scope = create_payload["project_scope_token"]
        registry_path = self.state / "projects" / "registry-v2.json"
        registry = json.loads(registry_path.read_text())
        self.registry_updated = "2026-08-04T05:00:01Z"
        registry["projects"][0]["updated_at"] = self.registry_updated
        registry_path.write_text(json.dumps(registry), encoding="utf-8")

        identity = created["note"]["identity"]
        update = {
            "identity": identity,
            "captured_at": "2026-09-20T08:00:10Z",
            "recording_state": "paused",
            "checkpoint_reason": "pause",
            "segments": [{
                "segment_id": "segment-1",
                "captured_at": "2026-09-20T08:00:10Z",
                "text": "same-project recovery",
            }],
        }
        update_payload = {
            "repo_path": str(self.repo),
            "project_scope_token": stale_scope,
            "request_id": "note-scope-checkpoint-1",
            "update": update,
            "provider": "codex",
        }
        with patch.object(orchestrator, "_read_body", return_value=update_payload):
            stale_status, stale = handler._route(
                "POST", "/v1/artifacts/notes/REP-N1/update"
            )
        self.assertEqual(stale_status, 422)
        self.assertEqual(stale["error"], "confirmed project scope token is stale")

        update_payload["project_scope_token"] = self.scope_token()
        with patch.object(orchestrator, "_read_body", return_value=update_payload):
            fresh_status, saved = handler._route(
                "POST", "/v1/artifacts/notes/REP-N1/update"
            )
        with patch.object(orchestrator, "_read_body", return_value=update_payload):
            retry_status, retry = handler._route(
                "POST", "/v1/artifacts/notes/REP-N1/update"
            )
        self.assertEqual(fresh_status, 200)
        self.assertEqual(retry_status, 200)
        self.assertFalse(saved["idempotent"])
        self.assertTrue(retry["idempotent"])
        self.assertEqual(saved["note"]["segments"], update["segments"])
        self.assertEqual(retry["note"], saved["note"])

        changed_identity = dict(identity)
        changed_identity["project_id"] = "another-project"
        changed_payload = {
            **update_payload,
            "request_id": "note-scope-wrong-project",
            "update": {**update, "identity": changed_identity},
        }
        with patch.object(orchestrator, "_read_body", return_value=changed_payload):
            changed_status, changed = handler._route(
                "POST", "/v1/artifacts/notes/REP-N1/update"
            )
        self.assertEqual(changed_status, 409)
        self.assertFalse(changed["retryable"])

    def test_retention_history_and_storage_client_contracts_are_scoped_and_provider_neutral(self):
        token = self.scope_token()
        preview = self.daemon.artifact_retention_preview(
            repo_path=str(self.repo),
            project_scope_token=token,
        )
        status = self.daemon.artifact_retention_status(
            repo_path=str(self.repo),
            project_scope_token=token,
        )
        history = self.daemon.artifact_history_search(
            repo_path=str(self.repo),
            project_scope_token=token,
            query="",
        )
        storage = self.daemon.artifact_storage_metrics(
            repo_path=str(self.repo),
            project_scope_token=token,
        )

        self.assertEqual(preview["nonterminal_ids"], ["RR-1"])
        self.assertEqual(preview["retained_terminal_ids"], [])
        self.assertEqual(preview["eviction_candidate_ids"], [])
        self.assertEqual(status["transaction"]["state"], "idle")
        self.assertEqual(status["remote_mode"], "local_only")
        self.assertIsNone(status["remote_name"])
        self.assertFalse(status["exposure_confirmation_required"])
        self.assertEqual(history, {"history": []})
        self.assertEqual(storage["retention"]["nonterminal_count"], 1)
        self.assertIn("tickets", storage["materialized"])
        self.assertIn("attachments", storage["materialized"])

        handler = object.__new__(orchestrator.Handler)
        handler.daemon = self.daemon
        query = urlencode({
            "repo_path": str(self.repo),
            "project_scope_token": token,
        })
        code, payload = handler._route(
            "GET", f"/v1/artifacts/retention/preview?{query}"
        )
        self.assertEqual(code, 200)
        self.assertEqual(payload["nonterminal_ids"], ["RR-1"])
        unscoped_code, unscoped = handler._route(
            "GET", f"/v1/artifacts/retention/preview?repo_path={self.repo}"
        )
        self.assertEqual(unscoped_code, 422)
        self.assertIn("scope token", unscoped["error"])

    def test_background_retention_uses_registered_scope_without_ui_and_respects_rollout_pause(self):
        with (
            patch.object(orchestrator, "prepare_project_retention", return_value=None) as prepare,
            patch.object(orchestrator, "sweep_automatic_retention", return_value={"state": "clean", "ticket_ids": []}) as sweep,
        ):
            results = self.daemon.sweep_artifact_retention()
            self.assertEqual([r["state"] for r in results], ["clean"])
            self.assertEqual(prepare.call_args.args[0], self.repo.resolve())
            self.assertEqual(sweep.call_count, 1)
            self.assertEqual(sweep.call_args.args[0].project_id, self.store.project_id)
            self.daemon.artifact_rollout.pause_cohort(
                PROJECT_OPT_IN, writers_drained=True, sync_frozen=True, reason_code="cas_failure",
            )
            self.daemon.sweep_artifact_retention()
            self.assertEqual(sweep.call_count, 1)

    def test_legacy_project_notes_are_empty_without_enabling_or_mutating_storage(self):
        before = self.store._head()
        with patch.object(self.daemon, "_artifact_lifecycle", return_value=None):
            result = self.daemon.artifact_note_list(repo_path=str(self.repo), project_scope_token=None)
        self.assertEqual(result["notes"], [])
        self.assertFalse(result["has_more"])
        self.assertEqual(result["total_count"], 0)
        self.assertEqual(result["sync"]["mode"], "disabled")
        self.assertEqual(self.store._head(), before)

    def test_legacy_history_explains_setup_without_artifact_writer_http_error(self):
        with patch.object(self.daemon, "_artifact_lifecycle", return_value=None):
            result = self.daemon.artifact_history_search(repo_path=str(self.repo), project_scope_token=None)
        self.assertEqual(result["history"], [])
        self.assertIn("automatic GitHub backup", result["recovery"])

    def test_background_retention_discovers_inactive_projects_and_isolates_failures(self):
        registry = self.daemon.project_registry_v2_path
        with patch.object(orchestrator, "prepare_project_retention", return_value={"state": "clean"}) as prepare:
            self.daemon.sweep_artifact_retention()
            self.assertEqual(prepare.call_count, 1)
        document = json.loads(registry.read_text())
        projects = [self.repo.resolve()]
        for name in ("newly-added", "newly-created"):
            repo = self.root / name
            repo.mkdir()
            projects.append(repo.resolve())
            document["projects"].append({
                "project_id": name, "selected_path": str(repo),
                "last_resolved_path": str(repo), "availability": "available",
            })
        registry.write_text(json.dumps(document))

        def prepare_project(repo, *_args, **_kwargs):
            if repo == self.repo.resolve():
                raise OSError("backup unavailable")
            return {"state": "clean"}

        with patch.object(orchestrator, "prepare_project_retention", side_effect=prepare_project) as prepare:
            results = self.daemon.sweep_artifact_retention()
        self.assertCountEqual([call.args[0] for call in prepare.call_args_list], projects)
        self.assertCountEqual([result["state"] for result in results], ["blocked", "clean", "clean"])
        self.assertEqual(document["active_project_id"], "daemon-project")

    def test_retention_status_blocks_non_github_remote_before_apply(self):
        remote = self.root / "origin.git"
        subprocess.run(
            ["git", "init", "--bare", "--quiet", str(remote)],
            check=True,
        )
        self.git("remote", "add", "origin", str(remote))

        snapshot = self.store.snapshot()
        config = snapshot.files[".orchestrator/config.toml"].decode("utf-8")
        self.assertIn('remote_sync = "local_only"', config)
        config = config.replace(
            'remote_sync = "local_only"',
            'remote_sync = "enabled"\nremote_name = "origin"',
        )
        self.store.mutate(ArtifactMutation(
            event_id="enable-local-retention-remote",
            actor_type="user",
            device_id="test-device",
            expected_base=snapshot.commit_id,
            operations=(ConfigWrite(config.encode("utf-8")),),
        ))
        for number in range(2, 28):
            self.write_ticket(f"RR-{number}", status="done")
        self.git(
            "push",
            "origin",
            "refs/heads/relay/artifacts:refs/heads/relay/artifacts",
        )

        status = self.daemon.artifact_retention_status(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
        )

        self.assertEqual(status["state"], "blocked")
        self.assertTrue(status["plan"]["eviction_candidate_ids"])
        self.assertTrue(
            any("github.com remote" in reason for reason in status["blocked_reasons"]),
            status["blocked_reasons"],
        )

    def test_ready_sweep_promotes_verified_archived_dependencies_through_artifact_writer(self):
        self.write_ticket("RR-archived", status="done")
        self.write_ticket(
            "RR-dependent",
            status="backlog",
            depends_on=("RR-archived",),
        )
        self.write_ticket("RR-spike", status="done", execution_mode="spike")
        self.write_ticket(
            "RR-spike-dependent",
            status="backlog",
            depends_on=("RR-spike",),
        )
        lifecycle = self.daemon._artifact_lifecycle(str(self.repo))
        self.assertIsNotNone(lifecycle)
        manager = ArtifactRetentionManager(
            self.store,
            lease_store=lifecycle.leases,
            enabled=True,
        )
        manager.delete(
            "RR-archived",
            event_id="archive-done-dependency",
            device_id="test-device",
        )
        manager.delete(
            "RR-spike",
            event_id="archive-spike-dependency",
            device_id="test-device",
        )
        summary = self.daemon.artifact_dependency_summary(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            ticket_id="RR-dependent",
        )
        self.assertTrue(summary["satisfied"])
        self.assertEqual(summary["dependencies"], [{
            "ticket_id": "RR-archived",
            "satisfied": True,
            "availability": "available",
            "recovery": None,
        }])
        before = self.store._head()

        with patch.object(
            self.daemon,
            "_capacity_wait_reason",
            return_value=("test capacity", None),
        ):
            result = self.daemon.sweep_ready_tickets(
                repo_path=str(self.repo),
                trigger="archived-dependency-test",
                project_scope_token=self.scope_token(),
            )

        self.assertEqual(result["promoted"], ["RR-dependent"])
        files = self.store.snapshot().files
        self.assertIn("status: ready", files[".orchestrator/RR-dependent.md"].decode())
        self.assertIn(
            "status: backlog",
            files[".orchestrator/RR-spike-dependent.md"].decode(),
        )
        self.assertIsNotNone(
            self.store._find_event(f"lifecycle:dependency-sweep:{before}")
        )

    def test_dependency_summary_keeps_incomplete_predecessor_unsatisfied(self):
        self.write_ticket("RR-incomplete", status="backlog")
        self.write_ticket(
            "RR-dependent",
            status="ready",
            depends_on=("RR-incomplete",),
        )

        summary = self.daemon.artifact_dependency_summary(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            ticket_id="RR-dependent",
        )

        self.assertFalse(summary["satisfied"])
        self.assertEqual(summary["dependencies"], [{
            "ticket_id": "RR-incomplete",
            "satisfied": False,
            "availability": "unsatisfied",
            "recovery": None,
        }])

    def test_dependency_summary_and_sweep_preserve_tampered_history_detail(self):
        self.write_ticket("RR-archived", status="done")
        self.write_ticket(
            "RR-dependent",
            status="ready",
            depends_on=("RR-archived",),
        )
        manager = ArtifactRetentionManager(self.store, enabled=True)
        manager.delete(
            "RR-archived",
            event_id="archive-tampered-dependency",
            device_id="test-device",
        )
        snapshot = self.store.snapshot()
        catalog = json.loads(snapshot.files[".orchestrator/archive-index.jsonl"])
        catalog["ticket_blob"] = self.store._tree_entries(snapshot.commit_id)[
            ".orchestrator/config.toml"
        ].oid
        self.replace_catalog(catalog, "tamper-archived-dependency")

        summary = self.daemon.artifact_dependency_summary(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            ticket_id="RR-dependent",
        )
        with patch.object(
            self.daemon,
            "_capacity_wait_reason",
            return_value=("test capacity", None),
        ):
            sweep = self.daemon.sweep_ready_tickets(
                repo_path=str(self.repo),
                trigger="tampered-dependency-test",
                project_scope_token=self.scope_token(),
            )

        dependency = summary["dependencies"][0]
        self.assertEqual(dependency["availability"], "tampered")
        self.assertIn("mismatch", dependency["recovery"])
        skipped = next(
            item for item in sweep["skipped"] if item["ticket_id"] == "RR-dependent"
        )
        self.assertEqual(skipped["reason"], "dependency_history_unavailable")
        self.assertEqual(skipped["availability"], "tampered")
        self.assertEqual(skipped["recovery"], dependency["recovery"])

    def test_dependency_summary_and_sweep_preserve_unavailable_history_detail(self):
        self.write_ticket("RR-archived", status="done")
        self.write_ticket(
            "RR-dependent",
            status="ready",
            depends_on=("RR-archived",),
        )
        manager = ArtifactRetentionManager(self.store, enabled=True)
        manager.delete(
            "RR-archived",
            event_id="archive-unavailable-dependency",
            device_id="test-device",
        )
        snapshot = self.store.snapshot()
        catalog = json.loads(snapshot.files[".orchestrator/archive-index.jsonl"])
        catalog["source_commit"] = "0" * 40
        self.replace_catalog(catalog, "unavailable-archived-dependency")

        summary = self.daemon.artifact_dependency_summary(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            ticket_id="RR-dependent",
        )
        with patch.object(
            self.daemon,
            "_capacity_wait_reason",
            return_value=("test capacity", None),
        ):
            sweep = self.daemon.sweep_ready_tickets(
                repo_path=str(self.repo),
                trigger="unavailable-dependency-test",
                project_scope_token=self.scope_token(),
            )

        dependency = summary["dependencies"][0]
        self.assertEqual(dependency["availability"], "needs_network")
        self.assertIn("deepen", dependency["recovery"])
        skipped = next(
            item for item in sweep["skipped"] if item["ticket_id"] == "RR-dependent"
        )
        self.assertEqual(skipped["reason"], "dependency_history_unavailable")
        self.assertEqual(skipped["availability"], "needs_network")
        self.assertEqual(skipped["recovery"], dependency["recovery"])

    def recover_spikes_after_restart(self) -> int:
        reconciled = self.daemon.runs.reconcile_on_startup()
        self.daemon._artifact_lifecycles.clear()
        self.daemon._recover_stalled_spikes(artifact_only=not reconciled)
        self.daemon._recover_artifact_lifecycle_leases()
        return reconciled

    def dispatch_spike(self, ticket_id: str, *, provider: str = "codex") -> dict:
        self.write_ticket(ticket_id, execution_mode="spike")
        with patch.object(Worker, "start"), patch.object(
            self.daemon, "_effective_worker_agent", return_value=(provider, "/usr/bin/true", {}),
        ):
            run = self.daemon.dispatch(
                ticket_id=ticket_id, repo_path=str(self.repo), project_scope_token=self.scope_token(),
            )["run"]
        self.addCleanup(orchestrator.remove_spike_workspace, Path(run["workspace_path"]))
        return run

    @staticmethod
    def spike_result(conclusion: str = "Go: the local interface supports this approach.") -> dict:
        return {
            "conclusions": [conclusion],
            "evidence": [{"source": "source.txt:1", "finding": "The snapshot contains the interface."}],
            "uncertainties": ["Runtime behavior requires separate evidence."],
            "recommended_next_steps": ["Review the findings before planning implementation."],
            "mutation_attempts": [],
            "research_access": {
                "status": "not_used",
                "detail": "The spike used only immutable local evidence.",
            },
        }

    @staticmethod
    def spike_event(provider: str, result: dict) -> str:
        if provider == "claude":
            return json.dumps({"type": "result", "structured_output": result})
        return json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": json.dumps(result)}})

    def ready_spike(self, run: dict) -> None:
        result = self.spike_result()
        Path(run["log_path"]).write_text(self.spike_event(run["provider_key"], result) + "\n")
        self.daemon._workers[run["id"]].spike_result = result
        self.daemon.runs.update(run["id"], state="SpikeResultReady", ended=True, exit_code=0)

    def edit_ticket(self, ticket_id: str, event_id: str, transform) -> None:
        snapshot = self.store.snapshot()
        content = transform(snapshot.files[f".orchestrator/{ticket_id}.md"].decode()).encode()
        self.store.mutate(ArtifactMutation(
            event_id=event_id, actor_type="pm", device_id="test-device",
            expected_base=snapshot.commit_id,
            operations=(TicketWrite(ticket_id, f"artifact-{ticket_id}", content),),
        ))

    def scope_token(self) -> str:
        payload = {
            "version": 1,
            "registrySchemaVersion": 2,
            "projectID": "daemon-project",
            "repositoryPath": str(self.repo.resolve()),
            "gitCommonDirectoryFingerprint": "daemon-fingerprint",
            "registryRecordUpdatedAt": datetime.fromisoformat(
                self.registry_updated.replace("Z", "+00:00")
            ).timestamp(),
            "issuedAt": datetime(2026, 8, 4, tzinfo=UTC).timestamp(),
        }
        return base64.b64encode(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")

    def write_ticket(
        self,
        ticket_id: str,
        *,
        status: str = "ready",
        depends_on: tuple[str, ...] = (),
        execution_mode: str = "implementation",
    ) -> None:
        dependencies = "[" + ", ".join(depends_on) + "]"
        markdown = f"""---
id: {ticket_id}
artifact_id: artifact-{ticket_id}
title: Daemon lifecycle
status: {status}
priority: high
execution_mode: {execution_mode}
activity_at: 2026-08-04T00:00:00.000000Z
depends_on: {dependencies}
run_id: null
canceled: false
worker_model: strong
worker_effort: high
worker_sizing_rationale: daemon fixture
worker_provider_notes: provider-neutral fixture
---

## Description

Exercise the artifact lifecycle through the daemon.
""".encode("utf-8")
        self.store.mutate(ArtifactMutation(
            event_id=f"write-{ticket_id}",
            actor_type="pm",
            device_id="test-device",
            expected_base=self.store._head(),
            operations=(TicketWrite(ticket_id, f"artifact-{ticket_id}", markdown),),
        ))

    def replace_catalog(self, entry: dict[str, object], event_id: str) -> None:
        content = (json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n").encode()
        self.store.mutate(ArtifactMutation(
            event_id=event_id,
            actor_type="system",
            device_id="test-device",
            expected_base=self.store._head(),
            operations=(ArchiveIndexWrite(content),),
        ))

    def git(self, *arguments: str) -> str:
        command = ["git"]
        if not arguments or arguments[0] != "-C":
            command.extend(["-C", str(self.repo)])
        command.extend(arguments)
        process = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(
            process.returncode,
            0,
            msg=f"{' '.join(command)} failed: {process.stderr}",
        )
        return process.stdout.strip()


if __name__ == "__main__":
    unittest.main()
