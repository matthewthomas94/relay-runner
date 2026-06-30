import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class SkillCleanupTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
