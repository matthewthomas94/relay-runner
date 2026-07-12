import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class SkillCleanupTests(unittest.TestCase):
    def test_relay_bridge_install_uses_pm_frontstage_wording(self):
        script = (ROOT / "scripts" / "relay-bridge").read_text()

        self.assertIn("You are the foreground orchestrator/PM for the user", script)
        self.assertIn("Raw Relay command captures are private metadata", script)
        self.assertIn("Create or edit visible `.orchestrator/` tickets only as PM management work", script)
        self.assertNotIn("persistent orchestrator receives the same private Relay metadata", script)

    def test_relay_bridge_install_scrubs_legacy_pm_sync_surfaces(self):
        script = (ROOT / "scripts" / "relay-bridge").read_text()

        self.assertIn('local legacy_pm_sync_md="$cmds_dir/pm-sync.md"', script)
        self.assertIn('local legacy_codex_pm_sync_dir="$codex_skills_dir/pm-sync"', script)
        self.assertIn('rm -f "$legacy_pm_sync_md"', script)
        self.assertIn('rm -rf "$legacy_codex_pm_sync_dir"', script)

    def test_relay_orchestrator_install_and_uninstall_scrub_legacy_pm_sync_surfaces(self):
        script = (ROOT / "scripts" / "relay-orchestrator").read_text()

        self.assertIn('LEGACY_PM_SYNC_MD="$CMDS_DIR/pm-sync.md"', script)
        self.assertIn('LEGACY_CODEX_PM_SYNC_DIR="$CODEX_SKILLS_DIR/pm-sync"', script)
        self.assertIn('rm -f "$LEGACY_LINK_MD" "$LEGACY_ORCHESTRATE_MD" "$LEGACY_PM_SYNC_MD"', script)
        self.assertIn('rm -rf "$LEGACY_CODEX_PM_SYNC_DIR"', script)
        self.assertIn('rm -rf "$CODEX_DISPATCH_DIR" "$CODEX_WORKFLOW_DIR" "$LEGACY_CODEX_PM_SYNC_DIR"', script)

    def test_relay_orchestrator_install_uses_pm_frontstage_wording(self):
        script = (ROOT / "scripts" / "relay-orchestrator").read_text()

        self.assertIn("You are the foreground orchestrator/PM for the user", script)
        self.assertIn("Raw Relay command captures are private metadata", script)
        self.assertIn("Create or edit visible `.orchestrator/` tickets only as PM management work", script)
        self.assertNotIn("PM frontstage → persistent orchestrator → worker", script)

    def test_provider_bridge_skills_accept_app_managed_sessions(self):
        script = (ROOT / "scripts" / "relay-bridge").read_text()
        preflight = (
            'if [ "${RELAY_RUNNER_APP_SESSION:-0}" = "1" ] '
            "|| pgrep -f 'relay-runner' > /dev/null 2>&1"
        )

        self.assertEqual(script.count(preflight), 2)
        self.assertIn(
            'if [ "${RELAY_RUNNER_APP_SESSION:-0}" != "1" ] '
            "&& ! pgrep -f 'relay-runner' > /dev/null 2>&1",
            script,
        )

    def test_shell_installers_prefer_chatgpt_codex_before_legacy_app(self):
        chatgpt = "/Applications/ChatGPT.app/Contents/Resources/codex"
        legacy = "/Applications/Codex.app/Contents/Resources/codex"

        for relative_path in ["scripts/relay-bridge", "scripts/relay-orchestrator"]:
            script = (ROOT / relative_path).read_text()
            self.assertIn(chatgpt, script)
            self.assertIn(legacy, script)
            self.assertLess(script.index(chatgpt), script.index(legacy))


if __name__ == "__main__":
    unittest.main()
