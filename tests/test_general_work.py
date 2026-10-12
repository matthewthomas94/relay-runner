from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services"))
from command_actions import classify_command, format_command_for_agent, resolve_command_action
from general_work import GeneralWorkStore, general_worker_environment
from personal_file_storage import PersonalFileStorage
from intent_arbitration import normalize_voice_work_items
from relay_authorization import allowed_mutations_for_metadata, mutation_allowed, record_command_authorization
import orchestrator


class GeneralWorkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.started = []
        self.store = GeneralWorkStore(self.root, command_factory=lambda provider: (provider or "codex", ["fake-provider"]),
                                      runner=self.successful_runner)

    def tearDown(self):
        self.temp.cleanup()

    def successful_runner(self, command, workspace, prompt, run_id, cancelled):
        self.started.append((workspace, prompt, run_id))
        (workspace / "report.md").write_text("Verified local report\n")
        (workspace / "result.json").write_text(json.dumps({"summary": "Prepared report", "criteria": [
            {"criterion": "Produce a report", "evidence": "report.md contains the reviewed draft"}],
            "artifacts": ["report.md"]}))
        return 0

    def create(self, request_id="create-1"):
        return self.store.create(title="Prepare a report", description="Produce a local draft for review; do not publish.",
                                 acceptance_criteria=["Produce a report"], request_id=request_id)["task"]

    def wait_status(self, task_id, expected):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            task = self.store.get(task_id)["task"]
            if task["status"] in expected:
                return task
            time.sleep(0.01)
        self.fail(f"Task did not reach {expected}: {task}")

    def test_backlog_is_canonical_idempotent_and_never_executes(self):
        task = self.create()
        again = self.create()
        self.assertEqual(task["id"], again["id"])
        self.assertEqual(task["status"], "backlog")
        self.assertEqual(self.started, [])
        self.assertTrue(task["id"].startswith("GEN-"))
        self.assertFalse((self.root / ".git").exists())
        with self.assertRaisesRegex(ValueError, "different"):
            self.store.create(title="Different", description="Other", acceptance_criteria=["Other"], request_id="create-1")
        restored = GeneralWorkStore(self.root)
        self.assertEqual(restored.get(task["id"])["task"]["description"], task["description"])

    def test_both_providers_execute_isolated_tasks_with_reviewed_manifest(self):
        paths = []
        for provider in ("codex", "claude"):
            task = self.create(provider)
            self.store.dispatch(task["id"], provider=provider)
            task = self.wait_status(task["id"], {"awaiting_review"})
            run = task["runs"][-1]
            paths.append(run["workspace_path"])
            self.assertEqual(run["provider"], provider)
            self.assertEqual(run["artifact_manifest"][0]["path"], "report.md")
            self.assertFalse((Path(run["workspace_path"]) / ".git").exists())
            done = self.store.review(task["id"], run_id=run["id"], approve=True,
                                     summary="Opened report.md and verified the requested report")
            self.assertEqual(done["task"]["status"], "done")
            self.assertIn("reviewed", [event["kind"] for event in self.store.get(task["id"])["events"]])
        self.assertNotEqual(*paths)

    def test_review_refuses_changed_output_or_stale_run(self):
        task = self.create()
        self.store.dispatch(task["id"])
        task = self.wait_status(task["id"], {"awaiting_review"})
        run = task["runs"][-1]
        with self.assertRaisesRegex(ValueError, "current"):
            self.store.review(task["id"], run_id="older-run", approve=True, summary="Review")
        (Path(run["workspace_path"]) / "report.md").write_text("changed")
        with self.assertRaisesRegex(ValueError, "changed"):
            self.store.review(task["id"], run_id=run["id"], approve=True, summary="Review")
        self.assertEqual(self.store.get(task["id"])["task"]["status"], "awaiting_review")
        self.store.review(task["id"], run_id=run["id"], approve=False, summary="Output changed; regenerate")
        self.store.dispatch(task["id"])
        retry = self.wait_status(task["id"], {"awaiting_review"})
        self.assertEqual(len(retry["runs"]), 2)
        self.assertNotEqual(retry["runs"][-1]["workspace_path"], run["workspace_path"])

    def test_exit_zero_without_criterion_evidence_fails_recoverably(self):
        def missing_result(command, workspace, prompt, run_id, cancelled):
            (workspace / "result.json").write_text(json.dumps({"summary": "Done", "criteria": [], "artifacts": ["report.md"]}))
            return 0
        self.store.runner = missing_result
        task = self.create()
        self.store.dispatch(task["id"])
        failed = self.wait_status(task["id"], {"failed"})
        self.assertIn("criterion", failed["runs"][-1]["error"])
        self.store.runner = self.successful_runner
        self.store.dispatch(task["id"])
        self.wait_status(task["id"], {"awaiting_review"})

    def test_symlink_and_path_escape_outputs_are_rejected(self):
        workspace = self.root / "workspace"
        workspace.mkdir()
        outside = self.root / "private.txt"
        outside.write_text("private")
        (workspace / "link").symlink_to(outside)
        for path in ("../private.txt", "link", str(outside), "worker.log"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.store._manifest(workspace, [path])

    def test_cancel_one_task_preserves_other_and_blocks_stale_cancel(self):
        gate = threading.Event()
        def waiting(command, workspace, prompt, run_id, cancelled):
            gate.set()
            cancelled.wait(2)
            return 1
        self.store.runner = waiting
        task = self.create()
        other = self.create("other")
        self.store.dispatch(task["id"])
        self.assertTrue(gate.wait(1))
        run = self.store.get(task["id"])["task"]["runs"][-1]
        self.assertTrue(self.store.dispatch(task["id"])["already_active"])
        with self.assertRaisesRegex(ValueError, "current"):
            self.store.cancel(task["id"], run_id="unrelated")
        self.store.cancel(task["id"], run_id=run["id"])
        self.wait_status(task["id"], {"canceled"})
        self.assertEqual(self.store.get(other["id"])["task"]["status"], "backlog")

    def test_restart_does_not_replay_interrupted_work(self):
        task = self.create()
        with self.store._connect() as db:
            task["status"] = "in_progress"
            task["runs"] = [{"id": "old", "state": "running", "workspace_path": "preserved"}]
            self.store._save(db, task, "dispatched", "old")
        restarted = GeneralWorkStore(self.root, command_factory=lambda provider: self.fail("Restart dispatched work"))
        recovered = restarted.get(task["id"])["task"]
        self.assertEqual(recovered["status"], "interrupted")
        self.assertIn("explicitly retry", recovered["runs"][-1]["error"])

    def test_real_subprocess_can_complete_without_a_git_repo(self):
        script = self.root / "fixture.py"
        script.write_text("import json, pathlib, sys\nsys.stdin.read()\npathlib.Path('draft.txt').write_text('local output')\n"
                          "pathlib.Path('result.json').write_text(json.dumps({'summary':'Ready','criteria':[{'criterion':'Produce a report','evidence':'draft.txt'}],'artifacts':['draft.txt']}))\n")
        self.store.runner = self.store._run_process
        self.store.command_factory = lambda provider: ("codex", [sys.executable, str(script)])
        task = self.create()
        self.store.dispatch(task["id"])
        completed = self.wait_status(task["id"], {"awaiting_review", "failed"})
        self.assertEqual(completed["status"], "awaiting_review", completed)
        self.assertTrue((Path(completed["runs"][-1]["workspace_path"]) / "draft.txt").is_file())

    def test_review_registers_immutable_outputs_without_upload_consent(self):
        storage = PersonalFileStorage(self.root, github=Mock())
        self.store.personal_storage = storage
        task = self.create()
        self.store.dispatch(task["id"])
        task = self.wait_status(task["id"], {"awaiting_review"})
        run = task["runs"][-1]
        source = Path(run["workspace_path"]) / "report.md"
        self.assertEqual(storage.list_files()["files"], [])
        done = self.store.review(task["id"], run_id=run["id"], approve=True, summary="Inspected report.md")
        reference = done["task"]["runs"][-1]["artifact_references"][0]
        self.assertFalse(source.exists(), "Verified duplicate should be adopted after receipt commit")
        self.assertFalse(storage.reference(reference["artifact_id"])["approved"])
        materialized = self.store.artifact(task["id"], run_id=run["id"], artifact_id=reference["artifact_id"])
        self.assertEqual(Path(materialized["absolute_path"]).read_text(), "Verified local report\n")
        with self.assertRaisesRegex(ValueError, "does not belong"):
            self.store.artifact(task["id"], run_id=run["id"], artifact_id="unrelated")
        storage.github.assert_not_called()
        storage.github.publish.assert_not_called()
        storage.db.close()

    def test_storage_failure_preserves_unreviewed_output_and_canonical_status(self):
        self.store.personal_storage = SimpleNamespace(register_file=Mock(side_effect=OSError("disk unavailable")))
        task = self.create()
        self.store.dispatch(task["id"])
        run = self.wait_status(task["id"], {"awaiting_review"})["runs"][-1]
        with self.assertRaises(OSError):
            self.store.review(task["id"], run_id=run["id"], approve=True, summary="Verified output")
        self.assertEqual(self.store.get(task["id"])["task"]["status"], "awaiting_review")
        self.assertTrue((Path(run["workspace_path"]) / "report.md").is_file())

    def test_recovery_refuses_duplicate_execution_and_cancels_verified_pid_only(self):
        task = self.create()
        with self.store._connect() as db:
            task["status"] = "in_progress"
            task["runs"] = [{"id": "old", "state": "running", "workspace_path": "preserved",
                             "worker_pid": 123456, "process_identity": "exact-start"}]
            self.store._save(db, task, "dispatched", "old")
        restarted = GeneralWorkStore(self.root, command_factory=Mock())
        with patch.object(GeneralWorkStore, "_process_identity", return_value="exact-start"), \
                patch("general_work.os.killpg") as kill:
            with self.assertRaisesRegex(ValueError, "still running"):
                restarted.dispatch(task["id"])
            with self.assertRaisesRegex(ValueError, "current"):
                restarted.cancel(task["id"], run_id="unrelated-run")
            kill.assert_not_called()
            restarted.cancel(task["id"], run_id="old")
            kill.assert_called_once()
            self.assertEqual(kill.call_args.args[0], 123456)
        restarted.command_factory.assert_not_called()

    def test_preflight_failure_creates_no_run_and_keeps_backlog(self):
        self.store.preflight = Mock(side_effect=ValueError("Sign in with subscription"))
        task = self.create()
        with self.assertRaisesRegex(ValueError, "subscription"):
            self.store.dispatch(task["id"], provider="claude")
        self.assertEqual(self.store.get(task["id"])["task"]["runs"], [])
        self.assertEqual(self.store.get(task["id"])["task"]["status"], "backlog")
        self.assertEqual(self.started, [])

    def test_recovery_blocks_unknown_live_process_without_canceling_it(self):
        for saved_identity, current_identity in ((None, "current"), ("saved", None), (None, None)):
            with self.subTest(saved_identity=saved_identity, current_identity=current_identity):
                task = self.create(request_id=str((saved_identity, current_identity)))
                with self.store._connect() as db:
                    task.update(status="interrupted", runs=[{"id": "old", "state": "interrupted",
                                "worker_pid": 123456, "process_identity": saved_identity}])
                    self.store._save(db, task, "interrupted", "old")
                with patch.object(GeneralWorkStore, "_process_identity", return_value=current_identity), \
                        patch("general_work.os.kill"), patch("general_work.os.killpg") as kill_group:
                    with self.assertRaisesRegex(ValueError, "still running"):
                        self.store.dispatch(task["id"])
                    with self.assertRaisesRegex(ValueError, "cannot be verified"):
                        self.store.cancel(task["id"], run_id="old")
                    kill_group.assert_not_called()
                self.assertEqual(self.store.get(task["id"])["task"]["status"], "interrupted")
        with patch.object(GeneralWorkStore, "_process_identity", return_value=None), \
                patch("general_work.os.kill", side_effect=ProcessLookupError):
            self.assertFalse(self.store._preserved_process({"worker_pid": 123456}))
        with patch.object(GeneralWorkStore, "_process_identity", return_value="other-start"):
            self.assertFalse(self.store._preserved_process({"worker_pid": 123456, "process_identity": "saved"}))


class GeneralDaemonContractTests(unittest.TestCase):
    def test_preflight_requires_actual_subscription_for_both_providers(self):
        for output, status in (("Logged in using API key", 0), ("Not logged in", 1)):
            with patch.object(orchestrator.subprocess, "run", return_value=SimpleNamespace(
                    returncode=status, stdout=output, stderr="")) as probe:
                with self.assertRaisesRegex(ValueError, "ChatGPT subscription"):
                    orchestrator.Daemon._general_worker_preflight("codex", ["/fake/codex", "exec"], Path("/tmp"))
                self.assertIn('forced_login_method="chatgpt"', probe.call_args.args[0])
        with patch.object(orchestrator.subprocess, "run", return_value=SimpleNamespace(
                returncode=0, stdout="", stderr="Logged in using ChatGPT")):
            orchestrator.Daemon._general_worker_preflight("codex", ["/fake/codex", "exec"], Path("/tmp"))
        with patch.object(orchestrator, "_claude_subscription_error", return_value="Claude subscription expired"):
            with self.assertRaisesRegex(ValueError, "subscription expired"):
                orchestrator.Daemon._general_worker_preflight("claude", ["/fake/claude", "-p"], Path("/tmp"))

    def test_both_provider_commands_enforce_local_scope_and_subscription_route(self):
        daemon = object.__new__(orchestrator.Daemon)
        for provider in ("codex", "claude"):
            daemon._effective_worker_agent = lambda: (provider, "/fake/" + provider, {})
            selected, command = daemon._general_worker_command()
            self.assertEqual(selected, provider)
            self.assertFalse(any("dangerously" in arg for arg in command))
            if provider == "codex":
                self.assertIn("workspace-write", command)
                self.assertIn("--skip-git-repo-check", command)
                self.assertIn("--ignore-user-config", command)
                self.assertIn('forced_login_method="chatgpt"', command)
                self.assertIn('sandbox_workspace_write.writable_roots=[]', command)
            else:
                self.assertIn("--restricted", command)
                self.assertIn("dontAsk", command)
                settings = json.loads(command[command.index("--settings") + 1])
                # --restricted owns file-tool confinement; duplicating it in settings
                # alongside sandbox configuration hangs the supported Claude CLI.
                self.assertNotIn("permissions", settings)
                self.assertTrue(settings["sandbox"]["enabled"])
                self.assertFalse(settings["sandbox"]["allowUnsandboxedCommands"])
                self.assertIn("Edit(./**)", command[command.index("--allowedTools") + 1])
                self.assertEqual(command[command.index("--setting-sources") + 1], "")

    def test_worker_environment_excludes_project_and_metered_credentials(self):
        variables = {"ANTHROPIC_API_KEY": "secret", "ANTHROPIC_AUTH_TOKEN": "secret",
                     "ANTHROPIC_BASE_URL": "https://gateway.invalid", "CLAUDE_CODE_USE_BEDROCK": "1",
                     "OPENAI_API_KEY": "secret", "CODEX_API_KEY": "secret",
                     "RELAY_PROJECT_SCOPE_TOKEN": "project", "RELAY_PROJECT_PATH": "/repo",
                     "RELAY_PROJECT_SCOPE_VERSION": "1", "RELAY_SESSION_SCOPE": "project",
                     "RELAY_CONTEXT_ID": "foreground", "RELAY_CONTEXT_WORKING_DIRECTORY": "/repo",
                     "RELAY_SESSION_BINDING_PATH": "/binding", "RELAY_PROVIDER_SESSION_ID": "provider",
                     "RELAY_PROVIDER_PROCESS_ID": "42",
                     "RELAY_APP_SESSION_ID": "app", "RELAY_GENERAL_FILES_ROOT": "/stale",
                     "CLAUDE_CODE_OAUTH_TOKEN": "subscription", "PATH": "/bin"}
        with patch.dict(os.environ, variables, clear=True):
            self.assertEqual(general_worker_environment("/managed/files"), {"CLAUDE_CODE_OAUTH_TOKEN": "subscription",
                "PATH": "/bin", "RELAY_SESSION_SCOPE": "general", "RELAY_GENERAL_FILES_ROOT": "/managed/files"})

    def test_http_canonical_writer_and_no_dispatch_authorization(self):
        with tempfile.TemporaryDirectory() as directory:
            store = GeneralWorkStore(Path(directory), command_factory=Mock())
            handler = object.__new__(orchestrator.Handler)
            handler.daemon = SimpleNamespace(general_work=store, personal_storage=PersonalFileStorage(Path(directory), github=Mock()))
            body = {"title": "Local report", "description": "Prepare local report", "acceptance_criteria": ["Report"],
                    "request_id": "http-report", "relay_command_seq": 1, "relay_command_id": "backlog"}
            ledger = Path(directory) / "authorizations.json"
            record_command_authorization(ledger, {"relay_command_seq": 1, "relay_command_id": "backlog",
                "action": "create_ticket", "source_text": "Create a ticket, but do not dispatch"})
            with patch.object(orchestrator, "RELAY_COMMAND_AUTHORIZATION_FILE", ledger), \
                    patch.object(orchestrator, "_relay_command_current", return_value=True), \
                    patch.object(orchestrator, "_read_body", return_value=body):
                code, created = handler._route("POST", "/v1/general/tasks")
                self.assertEqual(code, 201, created)
                identifier = created["task"]["id"]
                code, rejected = handler._route("POST", f"/v1/general/tasks/{identifier}/dispatch")
                self.assertEqual(code, 400, rejected)
                self.assertEqual(store.get(identifier)["task"]["status"], "backlog")
            store.command_factory.assert_not_called()
            code, catalog = handler._route("GET", "/v1/general/tasks")
            self.assertEqual(code, 200)
            self.assertEqual(catalog["tasks"][0]["id"], identifier)
            code, status = handler._route("GET", "/v1/personal-storage/status")
            self.assertEqual(code, 200)
            self.assertFalse(status["connected"])
            handler.daemon.personal_storage.db.close()


class GeneralCommandRoutingTests(unittest.TestCase):
    def test_general_scope_ignores_managed_cwd_as_project_authority(self):
        with patch.dict(os.environ, {"RELAY_SESSION_SCOPE": "general", "RELAY_GENERAL_FILES_ROOT": "/tmp/rr/files"}):
            action = resolve_command_action("Prepare a multi-file report", repo_path="/tmp/rr/files")
        self.assertEqual(action.scope, "general")
        self.assertIsNone(action.repo_path)
        self.assertIn("general_task", format_command_for_agent(action))

    def test_project_request_without_confirmed_repo_needs_target(self):
        action = resolve_command_action("Fix the source code in report.py")
        self.assertEqual(action.kind, "needs_project")
        self.assertIsNone(action.repo_path)
        project = resolve_command_action("Fix the source code in report.py", repo_path="/tmp/confirmed-project")
        self.assertEqual(project.scope, "project")
        self.assertEqual(project.repo_path, "/private/tmp/confirmed-project" if sys.platform == "darwin" else "/tmp/confirmed-project")

    def test_short_draft_action_and_discussion_never_need_ticket(self):
        self.assertEqual(classify_command("Create a short local draft for my introduction").kind, "direct_action")
        for text in ("Just discuss preparing a multi-file report", "Research whether this is feasible", "What is the status?"):
            with self.subTest(text=text):
                self.assertFalse(resolve_command_action(text).requires_ticket)
        tracked = resolve_command_action("Track research into public transport options")
        self.assertTrue(tracked.requires_ticket)
        self.assertEqual(tracked.scope, "general")

    def test_general_identity_routes_to_general_board_and_mixed_turn_stays_unresolved(self):
        general = resolve_command_action("Dispatch GEN-0123456789ABCDEF", repo_path="/tmp/unrelated-repo")
        self.assertEqual(general.scope, "general")
        self.assertIsNone(general.repo_path)
        mixed = resolve_command_action("Explain the options and create a report")
        self.assertEqual(mixed.kind, "conversation")
        self.assertFalse(mixed.requires_ticket)

    def test_general_inspection_and_cancellation_preserve_exact_identity(self):
        identifier = "GEN-0123456789ABCDEF"
        inspection = resolve_command_action(f"What is the status of {identifier}?")
        self.assertEqual(inspection.kind, "inspect_ticket")
        self.assertIn("general_task", format_command_for_agent(inspection))
        items = normalize_voice_work_items(f"Cancel {identifier}", relay_command_seq=1, relay_command_id="cancel")
        self.assertEqual(items[0].target, identifier)
        self.assertEqual(items[0].cancellation_scope.value, "ticket")
        allowed = allowed_mutations_for_metadata({"action": "dispatch_ticket", "source_text": f"Dispatch {identifier}",
                                                  "ticket_id": identifier})
        self.assertTrue(mutation_allowed({"allowed_mutations": allowed}, {"kind": "dispatch_ticket", "ticket_id": identifier}))
        self.assertFalse(mutation_allowed({"allowed_mutations": allowed}, {"kind": "dispatch_ticket", "ticket_id": "RR-123"}))

    def test_ambiguous_code_change_does_not_become_general_work(self):
        self.assertEqual(resolve_command_action("Fix the login bug").kind, "needs_project")


if __name__ == "__main__":
    unittest.main()
