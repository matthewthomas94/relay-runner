from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))

import orchestrator  # noqa: E402


PUBLIC_REPOSITORY = "https://github.com/octocat/Hello-World"
PINNED_REVISION = "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d"
COMMIT_URL = f"{PUBLIC_REPOSITORY}/commit/{PINNED_REVISION}"
RAW_URL = (
    "https://raw.githubusercontent.com/octocat/Hello-World/"
    f"{PINNED_REVISION}/README"
)


@unittest.skipUnless(
    os.environ.get("RELAY_RESEARCH_ACCESS_SMOKE") == "1",
    "opt-in smoke requires authenticated provider CLIs and public network access",
)
class ResearchAccessLiveSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-research-access-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.snapshot = self.root / "snapshot"
        (self.repo / ".orchestrator").mkdir(parents=True)
        (self.repo / ".orchestrator/RR-LIVE.md").write_text("immutable research ticket\n")
        (self.repo / "source.txt").write_text("immutable local evidence\n")
        self.git("init", "--quiet")
        self.git("config", "user.name", "Relay Research Smoke")
        self.git("config", "user.email", "research-smoke@example.invalid")
        self.git("add", ".orchestrator/RR-LIVE.md", "source.txt")
        self.git("commit", "--quiet", "-m", "fixture")
        self.git("branch", "-M", "main")
        orchestrator.create_spike_workspace(
            repo_path=str(self.repo), workspace_path=self.snapshot, base_branch="main"
        )
        self.addCleanup(orchestrator.remove_spike_workspace, self.snapshot)

    def git(self, *args: str) -> str:
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def test_provider_workers_retrieve_public_source_at_pinned_revision(self):
        providers = [
            provider.strip()
            for provider in os.environ.get(
                "RELAY_RESEARCH_ACCESS_PROVIDERS", "codex,claude"
            ).split(",")
            if provider.strip()
        ]
        self.assertTrue(providers)
        before_head = self.git("rev-parse", "HEAD")
        before_source = (self.snapshot / "source.txt").read_bytes()
        before_ticket = (self.snapshot / ".orchestrator/RR-LIVE.md").read_bytes()

        for provider in providers:
            with self.subTest(provider=provider):
                self.run_provider(provider)

        self.assertEqual(self.git("rev-parse", "HEAD"), before_head)
        self.assertEqual((self.snapshot / "source.txt").read_bytes(), before_source)
        self.assertEqual((self.snapshot / ".orchestrator/RR-LIVE.md").read_bytes(), before_ticket)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def run_provider(self, provider: str) -> None:
        self.assertIn(provider, {"codex", "claude"})
        binary = shutil.which(provider)
        self.assertIsNotNone(binary, f"{provider} CLI is required for the live smoke")

        provider_root = self.root / provider
        provider_root.mkdir()
        schema_path = provider_root / "result.schema.json"
        schema_path.write_text(json.dumps(orchestrator.SPIKE_RESULT_SCHEMA, indent=2))
        git_environment = (
            orchestrator.prepare_spike_git_environment(str(self.snapshot))
            if provider == "codex" else None
        )
        prompt = orchestrator.Daemon._build_spike_prompt(
            ticket={
                "id": "RR-LIVE",
                "title": "Verify default public research access",
                "body": (
                    "Use the provider web research tool to inspect the public repository at "
                    f"{PINNED_REVISION}. Cite {COMMIT_URL} and {RAW_URL}. Report the full pinned "
                    "revision and the README content established by that exact revision. Do not "
                    "substitute local knowledge or an unpinned branch."
                ),
            },
            repo_path=str(self.repo),
            workspace_path=str(self.snapshot),
            attempt=1,
            run_id=1,
            agent_kind=provider,
            git_path=(git_environment or {}).get("RELAY_SPIKE_GIT"),
        )
        store = orchestrator.RunsStore(provider_root / "runs.db")
        run_id = store.insert(
            ticket_id="RR-LIVE",
            repo_path=str(self.repo),
            workspace_path=str(self.snapshot),
            branch="",
            execution_mode="spike",
            state="Starting",
            provider_key=provider,
        )
        run = store.get(run_id) or {}
        run["result_schema_path"] = str(schema_path)
        run["spike_git_environment"] = git_environment
        log_path = provider_root / "run.log"
        worker = orchestrator.Worker(
            run_id=run_id,
            run=run,
            prompt=prompt,
            agent_bin=str(binary),
            agent_kind=provider,
            store=store,
            log_path=log_path,
        )
        worker.start()
        self.assertIsNotNone(worker.thread)
        worker.thread.join(timeout=240)
        if worker.thread.is_alive():
            worker.cancel()
            self.fail(f"{provider} research worker did not finish within 240 seconds")

        completed = store.get(run_id) or {}
        self.assertEqual(
            completed.get("state"),
            "SpikeResultReady",
            f"{provider} research worker failed: {completed.get('last_error')}",
        )
        events = []
        for line in log_path.read_text().splitlines():
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        if provider == "codex":
            self.assertTrue(any(
                event.get("type") == "item.completed"
                and event.get("item", {}).get("type") == "web_search"
                for event in events
            ), "Codex must retrieve the evidence through its native web tool")
        result = worker.spike_result or {}
        self.assertEqual(result.get("research_access", {}).get("status"), "succeeded")
        evidence = "\n".join(
            f"{item.get('source', '')} {item.get('finding', '')}"
            for item in result.get("evidence", [])
        )
        report = "\n".join(result.get("conclusions", [])) + "\n" + evidence
        self.assertIn(PINNED_REVISION, report)
        self.assertIn(COMMIT_URL, evidence)
        self.assertIn(RAW_URL, evidence)


if __name__ == "__main__":
    unittest.main()
