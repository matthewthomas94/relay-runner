"""RR-487: the per-invocation tools that were Python scripts, now relay-rs.

Black-box checks of the wrapper scripts in scripts/ and of the relay-rs
subcommands no wrapper fronts, against a built ``rust/target/debug/relay-rs``
(``cargo build -p relay-rs`` in rust/). Each wrapper runs with RELAY_RS_BIN
pointing at that binary and an isolated HOME, so nothing touches the real
Application Support folder. Standard library only.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
RELAY_RS = ROOT / "rust" / "target" / "debug" / "relay-rs"
WRAPPERS = {
    "relay-ticket-history": "ticket-history",
    "relay-artifact-migrate": "artifact-migrate",
    "relay-artifact-rollout": "artifact-rollout",
    "relay-artifact-verify": "artifact-verify",
    "relay-runner-fresh-install": "fresh-install",
    "relay-work-style": "work-style",
}
SUBSCRIBED = {"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty",
              "subscriptionType": "max"}
MODELS = {"data": [
    {"id": "gpt-6-sol", "model": "gpt-6-sol", "defaultReasoningEffort": "medium",
     "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "medium"}],
     "inputModalities": ["text"]},
    {"id": "gpt-6.1-sol", "model": "gpt-6.1-sol", "defaultReasoningEffort": "high",
     "supportedReasoningEfforts": ["low", "high"], "inputModalities": ["text", "image"]},
    {"id": "gpt-7-sol", "model": "gpt-7-sol", "hidden": True},
]}


@unittest.skipUnless(os.access(RELAY_RS, os.X_OK),
                     "rust/target/debug/relay-rs is not built; run cargo build -p relay-rs in rust/")
class RelayRsCliWrapperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-rs-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(os.path.realpath(self.temporary.name))
        self.home = self.root / "home"
        self.home.mkdir()
        self.environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.home),
            "TMPDIR": str(self.root),
            "LC_ALL": "C",
            "RELAY_RS_BIN": str(RELAY_RS),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": str(self.root / "gitconfig"),
        }

    def run_tool(self, command, *, environment=None, cwd=None):
        return subprocess.run(
            [str(part) for part in command],
            env={**self.environment, **(environment or {})},
            cwd=cwd or self.root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=120,
            check=False,
        )

    def wrapper(self, name, *arguments, **options):
        return self.run_tool([SCRIPTS / name, *arguments], **options)

    def git_repo(self, name="project") -> Path:
        repo = self.root / name
        repo.mkdir()
        subprocess.run(["git", "init", "--initial-branch=main", "--quiet", str(repo)],
                       env={**os.environ, **self.environment}, check=True)
        return repo

    # -- the wrappers ---------------------------------------------------------

    def test_wrappers_run_relay_rs_without_python(self):
        for name, subcommand in WRAPPERS.items():
            with self.subTest(name=name):
                text = (SCRIPTS / name).read_text()
                self.assertIn(f'exec "$candidate" {subcommand} "$@"', text)
                self.assertNotIn("python", text.lower())
                process = self.wrapper(name, "--help")
                self.assertEqual(process.returncode, 0, process.stderr)
                self.assertIn("usage:", process.stdout)

    def test_a_wrapper_without_relay_rs_explains_what_it_needs(self):
        scripts = self.root / "copy" / "scripts"
        scripts.mkdir(parents=True)
        copy = scripts / "relay-work-style"
        copy.write_text((SCRIPTS / "relay-work-style").read_text())
        copy.chmod(0o755)
        process = self.run_tool([copy, "show"], environment={"RELAY_RS_BIN": ""})
        self.assertEqual(process.returncode, 1)
        self.assertEqual(
            process.stderr.strip(),
            "relay-work-style requires relay-rs from Relay Runner.app (or build rust/ with cargo)",
        )

    def test_usage_errors_exit_2_with_argparse_messages(self):
        process = self.wrapper("relay-work-style", "bogus")
        self.assertEqual(process.returncode, 2)
        self.assertTrue(process.stderr.startswith("usage: relay-work-style"), process.stderr)
        self.assertIn("argument action: invalid choice: 'bogus' (choose from 'show', 'set')",
                      process.stderr)
        process = self.wrapper("relay-runner-fresh-install", "--reset-profile", "everything")
        self.assertEqual(process.returncode, 2)
        self.assertIn("argument --reset-profile: invalid choice: 'everything'", process.stderr)
        process = self.wrapper("relay-artifact-migrate", "preview")
        self.assertEqual(process.returncode, 2)
        self.assertIn("the following arguments are required", process.stderr)

    def test_work_style_show_and_set(self):
        repo = self.git_repo()
        style_file = self.root / "session-work-style.json"
        environment = {"RELAY_SESSION_WORK_STYLE_FILE": str(style_file)}
        process = self.wrapper("relay-work-style", "show", "--repo", repo, environment=environment)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stdout,
                         "project: auto (decides per request, and asks when unsure), from the default\n")
        (repo / ".relay-runner.toml").write_text('work_style = "orchestrated"\n')
        process = self.wrapper("relay-work-style", "--repo", repo, environment=environment)
        self.assertEqual(process.stdout,
                         "project: orchestrated (turns changes into tickets for workers), "
                         "from the project's .relay-runner.toml\n")
        process = self.wrapper("relay-work-style", "set", "direct", "--repo", repo,
                               environment=environment)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stdout,
                         "project: direct (makes changes now, without tickets), from the session's choice\n")
        self.assertEqual(json.loads(style_file.read_text()), {"work_style": "direct"})
        process = self.wrapper("relay-work-style", "set", "--repo", repo, environment=environment)
        self.assertEqual(process.returncode, 2)
        self.assertIn("relay-work-style: error: set needs a style: auto, direct, orchestrated",
                      process.stderr)
        process = self.wrapper("relay-work-style", "show", "--repo", repo,
                               environment={**environment, "RELAY_WORK_STYLE": "bogus"})
        self.assertEqual(process.stdout,
                         "project: auto (decides per request, and asks when unsure), from RELAY_WORK_STYLE\n")

    def test_fresh_install_profile_preview_is_read_only_json(self):
        state = self.root / "relay-runner"
        state.mkdir()
        (state / "config.toml").write_text("provider = 'codex'\n")
        model = self.root / ".local/share/kokoro/kokoro-v1.0.onnx"
        model.parent.mkdir(parents=True)
        model.write_bytes(b"model")
        process = self.wrapper(
            "relay-runner-fresh-install", "--reset-profile", "voice-models",
            "--state-root", state, "--home-root", self.root, "--temporary-root", self.root / "t",
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        answer = json.loads(process.stdout)
        self.assertTrue(answer["ok"])
        result = answer["result"]
        self.assertEqual(result["action"], "reset_profile")
        self.assertEqual(result["profile"], "voice-models")
        self.assertEqual(result["state_files"], 1)
        self.assertEqual([item["name"] for item in result["reset_resources"]],
                         ["kokoro-model", "kokoro-voices"])
        self.assertEqual([item["present"] for item in result["reset_resources"]], [True, False])
        self.assertIn("Keychain credentials", result["machine_state_not_reset"])
        self.assertEqual(process.stdout, json.dumps(answer, sort_keys=True, indent=2) + "\n")
        self.assertTrue(model.exists())

    def test_fresh_install_refusals_are_json_with_exit_2(self):
        process = self.wrapper("relay-runner-fresh-install", "--state-root", self.root / "relay-runner")
        self.assertEqual(process.returncode, 2)
        answer = json.loads(process.stdout)
        self.assertEqual(answer, {
            "ok": False,
            "error": "Normal reinstall requires --app <reviewed Relay Runner.app>.",
            "recovery": "Build/select the app bundle, run preflight, then add --execute.",
        })
        self.assertEqual(process.stdout, json.dumps(answer, indent=2) + "\n")
        process = self.wrapper("relay-runner-fresh-install", "--reset-profile", "voice-models",
                               "--state-root", self.root / "not-relay")
        self.assertEqual(process.returncode, 2)
        self.assertIn("State root is not Relay-owned by name", json.loads(process.stdout)["error"])

    def test_cli_reset_uses_default_detector_without_matching_its_own_command_lineage(self):
        state = self.root / "Application Support/relay-runner"
        (state / "projects").mkdir(parents=True)
        (state / "config.toml").write_text("provider = 'codex'\n")
        trash = self.root / "Trash"
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fake_ps = fake_bin / "ps"
        fake_ps.write_text(
            "#!/bin/sh\n"
            "printf '%s %s %s\\n' \"$PPID\" 7001 '/workspace/relay-runner/rust/target/debug/relay-rs fresh-install --reset-profile relay-owned'\n"
            "printf '%s %s %s\\n' 7001 1 '/bin/bash /workspace/relay-runner/scripts/relay-runner-fresh-install --reset-profile relay-owned'\n"
        )
        fake_ps.chmod(0o755)
        environment = {"PATH": f"{fake_bin}{os.pathsep}{self.environment['PATH']}"}
        process = self.wrapper(
            "relay-runner-fresh-install",
            "--reset-profile", "relay-owned",
            "--execute",
            "--confirm-daemon-stopped",
            "--confirm-profile", "relay-owned",
            "--state-root", state,
            "--trash-root", trash,
            "--home-root", self.home,
            "--temporary-root", self.root / "tmp",
            environment=environment,
        )
        self.assertEqual(process.returncode, 0, process.stderr + process.stdout)
        self.assertTrue(json.loads(process.stdout)["ok"])
        self.assertFalse(state.exists())

    def test_cli_reset_refuses_a_running_relay_process_outside_its_lineage(self):
        state = self.root / "Application Support/relay-runner"
        state.mkdir(parents=True)
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fake_ps = fake_bin / "ps"
        fake_ps.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' '9001 1 /Applications/Relay Runner.app/Contents/MacOS/relay-orchestrator'\n"
        )
        fake_ps.chmod(0o755)
        process = self.wrapper(
            "relay-runner-fresh-install", "--reset-profile", "relay-owned", "--execute",
            "--confirm-daemon-stopped", "--confirm-profile", "relay-owned",
            "--state-root", state, "--trash-root", self.root / "Trash",
            "--home-root", self.home, "--temporary-root", self.root / "tmp",
            environment={"PATH": f"{fake_bin}{os.pathsep}{self.environment['PATH']}"},
        )
        self.assertEqual(process.returncode, 2)
        self.assertIn("Profile reset refused active Relay processes: 9001 1 ",
                      json.loads(process.stdout)["error"])
        self.assertTrue(state.is_dir())

    def test_ticket_history_search_in_a_plain_repository(self):
        repo = self.git_repo()
        process = self.wrapper("relay-ticket-history", "search", "x", "--repo", repo)
        self.assertIn(process.returncode, (0, 1, 2), process.stderr)
        self.assertNotIn("Traceback", process.stderr)
        self.assertNotIn("panicked", process.stderr)

    # -- subcommands without a wrapper ------------------------------------------

    def test_codex_model_resolves_from_the_catalogue_fixture(self):
        environment = {"RELAY_CODEX_MODEL_LIST_JSON": json.dumps(MODELS)}
        process = self.run_tool([RELAY_RS, "codex-model", "--family", "sol"], environment=environment)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stdout, json.dumps({
            "selectedFamily": "sol",
            "resolvedModel": "gpt-6.1-sol",
            "defaultReasoningEffort": "high",
            "supportedReasoningEfforts": ["low", "high"],
            "resolvedEffort": "high",
        }, separators=(",", ":")) + "\n")
        process = self.run_tool([RELAY_RS, "codex-model", "--family", "sol", "--effort", "xhigh"],
                                environment=environment)
        self.assertEqual(process.returncode, 2)
        self.assertIn("does not advertise reasoning effort 'xhigh'", process.stderr)
        process = self.run_tool([RELAY_RS, "codex-model", "--family", "luna"], environment=environment)
        self.assertEqual(process.returncode, 2)
        self.assertEqual(process.stderr.strip(),
                         "Codex model family 'luna' is unavailable in the provider catalogue")
        process = self.run_tool([RELAY_RS, "codex-model"], environment=environment)
        self.assertEqual(process.returncode, 2)
        self.assertIn("the following arguments are required: --family", process.stderr)

    def fake_claude(self, status: dict) -> Path:
        binary = self.root / "fake-claude"
        binary.write_text(
            "#!/bin/sh\n"
            'if [ "$1 $2 $3" = "auth status --json" ]; then\n'
            f"  printf '%s\\n' '{json.dumps(status)}'\n"
            "  exit 0\n"
            "fi\n"
            "exit 1\n"
        )
        binary.chmod(0o755)
        return binary

    def test_claude_subscription_exit_statuses(self):
        project = self.root / "project"
        project.mkdir()
        ready = self.run_tool([RELAY_RS, "claude-subscription", "--binary", self.fake_claude(SUBSCRIBED),
                               "--cwd", project, "--signal-login-required"])
        self.assertEqual(ready.returncode, 0, ready.stderr)
        self.assertEqual(ready.stderr, "")

        signed_out = self.fake_claude({"loggedIn": False, "authMethod": "none"})
        process = self.run_tool([RELAY_RS, "claude-subscription", "--binary", signed_out,
                                 "--cwd", project, "--signal-login-required"])
        self.assertEqual(process.returncode, 77)
        self.assertTrue(process.stderr.startswith("[Relay Runner] Relay Runner couldn't confirm"),
                        process.stderr)
        process = self.run_tool([RELAY_RS, "claude-subscription", "--binary", signed_out,
                                 "--cwd", project])
        self.assertEqual(process.returncode, 78)

        process = self.run_tool([RELAY_RS, "claude-subscription", "--binary", self.fake_claude(SUBSCRIBED),
                                 "--cwd", project, "--signal-login-required"],
                                environment={"ANTHROPIC_API_KEY": "not-a-real-key"})
        self.assertEqual(process.returncode, 78)
        self.assertIn("ANTHROPIC_API_KEY", process.stderr)
        self.assertNotIn("not-a-real-key", process.stderr)

    def test_harness_update_usage_errors(self):
        process = self.run_tool([RELAY_RS, "harness-update"])
        self.assertEqual(process.returncode, 2)
        self.assertIn("the following arguments are required: --provider, --command", process.stderr)
        process = self.run_tool([RELAY_RS, "harness-update", "--provider", "gemini", "--command", "x"])
        self.assertEqual(process.returncode, 2)
        self.assertIn("invalid choice: 'gemini' (choose from 'codex', 'claude')", process.stderr)

    def test_harness_update_reports_a_missing_claude_as_json(self):
        process = self.run_tool([RELAY_RS, "harness-update", "--provider", "claude",
                                 "--command", "relay-no-such-claude"])
        self.assertEqual(process.returncode, 1)
        self.assertEqual(json.loads(process.stdout), {
            "error": "Claude Code is not installed. Run setup before starting a session.",
        })
        self.assertTrue((self.home / "Library/Application Support/relay-runner/harnesses/claude.lock").exists())


if __name__ == "__main__":
    unittest.main()
