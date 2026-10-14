import contextlib
import importlib.machinery
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "build-instructions"


def load_script():
    loader = importlib.machinery.SourceFileLoader("build_instructions", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class BuildInstructionsTests(unittest.TestCase):
    def setUp(self):
        self.module = load_script()

    def run_check_with_compact(self, server, text):
        real_load = self.module.load

        def load(name):
            return text if name == f"compact/{server}" else real_load(name)

        out = io.StringIO()
        with mock.patch.object(self.module, "load", load), \
                mock.patch.object(sys, "argv", ["build-instructions", "--check"]), \
                contextlib.redirect_stdout(out), \
                self.assertRaises(SystemExit) as raised:
            self.module.main()
        return raised.exception.code, out.getvalue()

    def test_checked_in_artifacts_are_in_sync(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--check"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_compact_payloads_fit_claude_code_limit(self):
        self.assertEqual(self.module.oversized_compacts(), [])

    def test_check_fails_when_a_compact_payload_exceeds_the_limit(self):
        code, output = self.run_check_with_compact("relay-vision", "x" * 2049)
        self.assertEqual(code, 1)
        self.assertIn("compact/relay-vision.md is 2049 characters", output)

    def test_limit_counts_utf16_units_like_claude_code(self):
        # 1025 astral code points are 2050 JavaScript string units.
        code, output = self.run_check_with_compact("relay-actions", "\U0001F600" * 1025)
        self.assertEqual(code, 1)
        self.assertIn("compact/relay-actions.md is 2050 characters", output)

    def test_compact_orchestrator_payload_is_subscription_only(self):
        text = self.module.compact("relay-orchestrator")
        self.assertIn("Subscription only", text)
        self.assertIn("claude auth login", text)
        self.assertIn("get_relay_instructions", text)
        for line in text.splitlines():
            if "API key" in line:
                self.assertIn("Never suggest adding an API key", line)

    def test_check_fails_when_installed_command_text_drifts(self):
        installer = self.module.COMMAND_INSTALLER.read_text()
        stale = installer.replace("## Subscription-only provider access", "## Old heading", 1)
        self.assertNotEqual(stale, installer)
        self.assertEqual(self.module.installer_with_commands(stale), installer)
        with tempfile.TemporaryDirectory(dir=ROOT / "scripts") as temp:
            copy = Path(temp) / "relay-bridge"
            copy.write_text(stale)
            out = io.StringIO()
            with mock.patch.object(self.module, "COMMAND_INSTALLER", copy), \
                    mock.patch.object(sys, "argv", ["build-instructions", "--check"]), \
                    contextlib.redirect_stdout(out), \
                    self.assertRaises(SystemExit) as raised:
                self.module.main()
        self.assertEqual(raised.exception.code, 1)
        self.assertIn("relay-bridge", out.getvalue())

    def test_claude_block_uses_artifact_writer(self):
        block = self.module.concat(self.module.CLAUDE_MD)
        self.assertIn("Use the daemon's artifact-backed ticket writer", block)
        self.assertIn("replaces step 2's direct ticket-file write", block)
        self.assertIn("scripts/relay-ticket-history search", block)

    def generated_block(self, name):
        text = (ROOT / name).read_text()
        return text.split(self.module.BEGIN, 1)[1].split(self.module.END, 1)[0]

    def test_agents_md_carries_the_same_generated_block_as_claude_md(self):
        self.assertEqual(self.generated_block("AGENTS.md"), self.generated_block("CLAUDE.md"))
        block = self.generated_block("AGENTS.md")
        for heading in (
            "## Subscription-only provider access",
            "### Command action contract",
            "### Worker sizing",
            "### Voice turns",
            "### Spike follow-ups and recovery tools",
            "### Saved project notes",
        ):
            self.assertIn(heading, block)
        agents = (ROOT / "AGENTS.md").read_text()
        self.assertIn("~/.codex/AGENTS.md", agents.split(self.module.END, 1)[1])

    def test_check_fails_when_agents_md_block_drifts(self):
        agents = (ROOT / "AGENTS.md").read_text()
        stale = agents.replace("## Subscription-only provider access", "## Old heading", 1)
        self.assertNotEqual(stale, agents)
        with tempfile.TemporaryDirectory() as temp:
            copy = Path(temp) / "AGENTS.md"
            copy.write_text(stale)
            out = io.StringIO()
            with mock.patch.object(self.module, "GUIDANCE_FILES", ["CLAUDE.md", str(copy)]), \
                    mock.patch.object(sys, "argv", ["build-instructions", "--check"]), \
                    contextlib.redirect_stdout(out), \
                    self.assertRaises(SystemExit) as raised:
                self.module.main()
        self.assertEqual(raised.exception.code, 1)
        self.assertIn("AGENTS.md", out.getvalue())
        self.assertNotIn("CLAUDE.md", out.getvalue())


if __name__ == "__main__":
    unittest.main()
