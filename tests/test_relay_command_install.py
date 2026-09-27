"""Installed Relay commands and MCP registrations stay current (ticket G).

Every test runs relay-bridge from a throwaway app layout with HOME pointed at
a temp directory and fake `claude` / `codex` executables, so the user's real
~/.claude, ~/.codex and MCP registrations are never touched.
"""

import hashlib
import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
# Last commit before installed-command hashes were recorded.
PRE_MANIFEST_COMMIT = "279dc087"
EXPECTED_MCP = "relay-orchestrator-mcp"
OLD_MCP = "/Applications/Old Relay Runner.app/Contents/MacOS/relay-orchestrator-mcp"

COMMAND_FILES = {
    "claude-workflow": ".claude/commands/relay-workflow.md",
    "claude-dispatch": ".claude/commands/relay-dispatch.md",
    "codex-workflow": ".codex/skills/relay-workflow/SKILL.md",
    "codex-dispatch": ".codex/skills/relay-dispatch/SKILL.md",
    "claude-bridge": ".claude/commands/relay-bridge.md",
    "claude-stop": ".claude/commands/relay-stop.md",
    "codex-bridge": ".codex/skills/relay-bridge/SKILL.md",
    "codex-stop": ".codex/skills/relay-stop/SKILL.md",
}

FAKE_CLAUDE = r"""#!/bin/bash
state="$FAKE_MCP_STATE"
echo "claude $*" >> "$state/log"
[ "$1" = "mcp" ] || exit 0
case "$2" in
    get)
        for scope in local user; do
            if [ -f "$state/claude-$scope-$3" ]; then
                case "$scope" in
                    local) label="Local config (private to you in this project)" ;;
                    user) label="User config (available in all your projects)" ;;
                esac
                printf '%s:\n  Scope: %s\n  Status: ok\n  Type: stdio\n  Command: %s\n  Args:\n' \
                    "$3" "$label" "$(cat "$state/claude-$scope-$3")"
                exit 0
            fi
        done
        echo "No MCP server named \"$3\"." >&2
        exit 1
        ;;
    add) printf '%s' "$7" > "$state/claude-$4-$5" ;;
    remove) rm -f "$state/claude-$4-$5" ;;
esac
"""

FAKE_CODEX = r"""#!/bin/bash
state="$FAKE_MCP_STATE"
echo "codex $*" >> "$state/log"
[ "$1" = "mcp" ] || exit 0
case "$2" in
    get)
        if [ ! -f "$state/codex-$3" ]; then
            echo "Error: No MCP server named '$3' found." >&2
            exit 1
        fi
        printf '{"name":"%s","transport":{"type":"stdio","command":"%s","args":[]}}\n' \
            "$3" "$(cat "$state/codex-$3")"
        ;;
    add) printf '%s' "$5" > "$state/codex-$3" ;;
    remove) rm -f "$state/codex-$3" ;;
esac
"""


def load_build_instructions():
    path = ROOT / "scripts" / "build-instructions"
    loader = importlib.machinery.SourceFileLoader("build_instructions_g", str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def pre_manifest_script(name, commit=PRE_MANIFEST_COMMIT):
    result = subprocess.run(
        ["git", "-C", str(ROOT), "show", f"{commit}:scripts/{name}"],
        capture_output=True, text=True, check=False,
    )
    return result.stdout if result.returncode == 0 else None


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class RelayInstallHarness(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.home = self.root / "home"
        self.state = self.root / "mcp-state"
        self.project = self.root / "project"
        support = self.root / "Relay Runner.app" / "Contents" / "SharedSupport"
        self.scripts = support / "scripts"
        (support / "services").mkdir(parents=True)
        for directory in (self.home, self.state, self.project, self.scripts):
            directory.mkdir(parents=True, exist_ok=True)
        self.expected_mcp = self.root / "Relay Runner.app" / "Contents" / "MacOS" / EXPECTED_MCP
        executable(self.expected_mcp, "#!/bin/bash\nexit 0\n")
        executable(self.home / ".local" / "bin" / "claude", FAKE_CLAUDE)
        self.fake_bin = self.root / "bin"
        executable(self.fake_bin / "codex", FAKE_CODEX)
        self.install_script("relay-bridge", (ROOT / "scripts" / "relay-bridge").read_text())
        self.manifest = (
            self.home / "Library" / "Application Support" / "relay-runner"
            / "installed-commands.sha256"
        )

    def install_script(self, name, source):
        # Resolve Codex only through PATH so a real ChatGPT.app install is
        # never used by the test.
        start = source.find("find_codex_bin() {")
        if start != -1:
            end = source.index("\n}\n", start) + 3
            source = (
                source[:start]
                + 'find_codex_bin() {\n    command -v codex || echo ""\n}\n'
                + source[end:]
            )
        executable(self.scripts / name, source)

    def run_script(self, name, *args, cwd=None):
        env = {
            "HOME": str(self.home),
            "PATH": f"{self.fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "FAKE_MCP_STATE": str(self.state),
            "RELAY_DIAGNOSTICS_DIR": str(self.root / "diagnostics"),
        }
        return subprocess.run(
            [str(self.scripts / name), *args],
            cwd=str(cwd or self.project), env=env, text=True,
            capture_output=True, check=False,
        )

    def path(self, key):
        return self.home / COMMAND_FILES[key]


class InstalledCommandTests(RelayInstallHarness):
    def refresh(self):
        result = self.run_script("relay-bridge", "--refresh-skills")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_generated_command_text_is_installed_for_both_providers(self):
        self.refresh()
        build = load_build_instructions()
        for key, (name, provider) in {
            "claude-workflow": ("relay-workflow", "claude"),
            "claude-dispatch": ("relay-dispatch", "claude"),
            "codex-workflow": ("relay-workflow", "codex"),
            "codex-dispatch": ("relay-dispatch", "codex"),
        }.items():
            self.assertEqual(self.path(key).read_text(), build.command_file(name, provider), key)
        recorded = self.manifest.read_text()
        for key in COMMAND_FILES:
            digest = hashlib.sha256(self.path(key).read_bytes()).hexdigest()
            self.assertIn(f"{digest}  {self.path(key)}\n", recorded)

    def test_installed_command_text_is_subscription_only(self):
        self.refresh()
        for key in ("claude-workflow", "claude-dispatch", "codex-workflow", "codex-dispatch"):
            text = self.path(key).read_text()
            self.assertIn("Subscription-only provider access", text, key)
            self.assertIn("`claude auth login`", text, key)
            self.assertIn("`codex login`", text, key)
        for key in COMMAND_FILES:
            text = self.path(key).read_text()
            for line in text.splitlines():
                if "API_KEY" in line or "API key" in line or "api key" in line.lower():
                    self.assertIn("never", line.lower(), f"{key}: {line}")

    def test_workflow_text_is_current(self):
        self.refresh()
        for key in ("claude-workflow", "codex-workflow"):
            text = self.path(key).read_text()
            self.assertIn("`execution_mode`", text)
            self.assertIn("`spike`", text)
            self.assertIn("codex:astra", text)
            self.assertNotIn("`max` is Claude-only", text)
            self.assertIn("the foreground orchestrator does not perform the substantive review or merge", text)
            self.assertNotIn("Review those branches, merge them into the working branch", text)

    def test_outdated_unmodified_install_is_replaced_on_upgrade(self):
        # The previous app version recorded what it wrote.
        old = (ROOT / "scripts" / "relay-bridge").read_text().replace(
            "**MANDATORY orchestrator-mode prime.**", "**Older orchestrator prime.**", 1
        )
        self.install_script("relay-bridge", old)
        self.refresh()
        self.assertIn("Older orchestrator prime", self.path("claude-workflow").read_text())

        self.install_script("relay-bridge", (ROOT / "scripts" / "relay-bridge").read_text())
        self.refresh()
        text = self.path("claude-workflow").read_text()
        self.assertNotIn("Older orchestrator prime", text)
        self.assertEqual(text, load_build_instructions().command_file("relay-workflow", "claude"))

    def test_user_edit_with_relay_text_is_kept_after_recorded_install(self):
        self.refresh()
        edited = self.path("codex-workflow").read_text() + "\nMy own house rule.\n"
        self.path("codex-workflow").write_text(edited)
        self.path("claude-stop").write_text("my own stop command\n")

        result = self.refresh()
        self.assertEqual(self.path("codex-workflow").read_text(), edited)
        self.assertEqual(self.path("claude-stop").read_text(), "my own stop command\n")
        self.assertIn(f"Kept your edited {self.path('codex-workflow')}", result.stderr)

        forced = self.run_script("relay-bridge", "--install-skills")
        self.assertEqual(forced.returncode, 0, forced.stderr)
        self.assertNotIn("My own house rule.", self.path("codex-workflow").read_text())

    def test_user_edit_to_unrecorded_file_is_kept(self):
        self.path("claude-dispatch").parent.mkdir(parents=True)
        self.path("claude-dispatch").write_text("Dispatch the way I like it.\n")
        self.refresh()
        self.assertEqual(self.path("claude-dispatch").read_text(), "Dispatch the way I like it.\n")

    def test_pre_manifest_relay_installs_refresh_and_edits_survive(self):
        old_bridge = pre_manifest_script("relay-bridge")
        old_orchestrator = pre_manifest_script("relay-orchestrator")
        if old_bridge is None or old_orchestrator is None:
            self.skipTest("pre-manifest scripts unavailable in this checkout")
        self.install_script("relay-bridge", old_bridge)
        self.install_script("relay-orchestrator", old_orchestrator)
        for name in ("relay-bridge", "relay-orchestrator"):
            result = self.run_script(name, "--install-skills")
            self.assertEqual(result.returncode, 0, result.stderr)
        stale_workflow = self.path("claude-workflow").read_text()
        self.assertIn("`max` is Claude-only", stale_workflow)
        # A user edit that keeps all of Relay's text is still a user edit.
        edited = self.path("codex-dispatch").read_text() + "Always ping me first.\n"
        self.path("codex-dispatch").write_text(edited)

        self.install_script("relay-bridge", (ROOT / "scripts" / "relay-bridge").read_text())
        self.refresh()

        build = load_build_instructions()
        self.assertEqual(
            self.path("claude-workflow").read_text(),
            build.command_file("relay-workflow", "claude"),
        )
        self.assertEqual(
            self.path("codex-workflow").read_text(),
            build.command_file("relay-workflow", "codex"),
        )
        self.assertEqual(self.path("codex-dispatch").read_text(), edited)
        # The bridge commands the previous version wrote are recognised too.
        self.assertIn(str(self.path("claude-bridge")), self.manifest.read_text())
        self.assertIn(str(self.path("codex-stop")), self.manifest.read_text())

    def test_older_pre_manifest_bridge_command_with_substituted_paths_is_refreshed(self):
        # An older release whose bridge text differs from the current one.
        old_bridge = pre_manifest_script("relay-bridge", commit="eb059e24")
        if old_bridge is None:
            self.skipTest("older relay-bridge unavailable in this checkout")
        self.install_script("relay-bridge", old_bridge)
        self.assertEqual(self.run_script("relay-bridge", "--install-skills").returncode, 0)
        before = self.path("claude-bridge").read_text()
        self.assertIn(str(self.scripts / "relay-bridge"), before)

        self.install_script("relay-bridge", (ROOT / "scripts" / "relay-bridge").read_text())
        result = self.refresh()
        self.assertNotIn("Kept your edited", result.stderr)
        self.assertNotEqual(self.path("claude-bridge").read_text(), before)
        self.assertNotEqual(self.path("codex-bridge").read_text(), before)

    def test_legacy_pm_sync_cleanup_only_removes_recorded_relay_installs(self):
        user_md = self.home / ".claude" / "commands" / "pm-sync.md"
        user_skill = self.home / ".codex" / "skills" / "pm-sync"
        user_md.parent.mkdir(parents=True)
        user_md.write_text("my ledger sync\n")
        (user_skill / "scripts").mkdir(parents=True)
        (user_skill / "SKILL.md").write_text("---\nname: pm-sync\n---\nmine\n")
        (user_skill / "scripts" / "sync.sh").write_text("echo hi\n")

        self.refresh()
        self.run_script("relay-bridge", "--install-skills")
        self.assertEqual(user_md.read_text(), "my ledger sync\n")
        self.assertTrue((user_skill / "SKILL.md").exists())
        self.assertTrue((user_skill / "scripts" / "sync.sh").exists())

        # Recorded as Relay-installed and unmodified: removed.
        relay_skill = user_skill / "SKILL.md"
        shutil.rmtree(user_skill / "scripts")
        digest = hashlib.sha256(relay_skill.read_bytes()).hexdigest()
        with self.manifest.open("a") as manifest:
            manifest.write(f"{digest}  {relay_skill}\n")
        self.refresh()
        self.assertFalse(user_skill.exists())
        self.assertNotIn(str(relay_skill), self.manifest.read_text())
        self.assertTrue(user_md.exists())


class McpRegistrationTests(RelayInstallHarness):
    def register(self):
        result = self.run_script(
            "relay-bridge", "--register-mcp", "relay-orchestrator", EXPECTED_MCP, "Relay Orchestrator"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def claude_entry(self, scope):
        path = self.state / f"claude-{scope}-relay-orchestrator"
        return path.read_text() if path.exists() else None

    def codex_entry(self):
        path = self.state / "codex-relay-orchestrator"
        return path.read_text() if path.exists() else None

    def log(self):
        path = self.state / "log"
        return path.read_text() if path.exists() else ""

    def test_missing_registration_is_added_for_both_providers(self):
        result = self.register()
        self.assertEqual(self.claude_entry("user"), str(self.expected_mcp))
        self.assertEqual(self.codex_entry(), str(self.expected_mcp))
        self.assertIn("Registered Claude MCP server", result.stdout)
        self.assertIn("Registered Codex MCP server", result.stdout)

    def test_old_app_path_is_repaired_at_its_scope_for_both_providers(self):
        (self.state / "claude-user-relay-orchestrator").write_text(OLD_MCP)
        (self.state / "codex-relay-orchestrator").write_text(OLD_MCP)
        result = self.register()
        self.assertEqual(self.claude_entry("user"), str(self.expected_mcp))
        self.assertEqual(self.codex_entry(), str(self.expected_mcp))
        self.assertIn("Repaired Claude MCP server", result.stdout)
        self.assertIn("Repaired Codex MCP server", result.stdout)

    def test_stale_local_scope_is_repaired_at_local_scope(self):
        (self.state / "claude-local-relay-orchestrator").write_text(OLD_MCP)
        self.register()
        self.assertEqual(self.claude_entry("local"), str(self.expected_mcp))
        self.assertIsNone(self.claude_entry("user"))
        self.assertIn("claude mcp add -s local relay-orchestrator", self.log())

    def test_current_registration_is_left_alone(self):
        (self.state / "claude-user-relay-orchestrator").write_text(str(self.expected_mcp))
        (self.state / "codex-relay-orchestrator").write_text(str(self.expected_mcp))
        result = self.register()
        self.assertNotIn("mcp add", self.log())
        self.assertNotIn("mcp remove", self.log())
        self.assertEqual(result.stdout + result.stderr, "")

    def test_project_mcp_json_shadowing_is_reported_not_fixed(self):
        (self.state / "claude-user-relay-orchestrator").write_text(OLD_MCP)
        (self.project / ".mcp.json").write_text(json.dumps({
            "mcpServers": {"relay-orchestrator": {"command": OLD_MCP, "args": []}}
        }))
        result = self.register()
        self.assertNotIn("claude mcp add", self.log())
        self.assertNotIn("Registered Claude", result.stdout)
        self.assertNotIn("Repaired Claude", result.stdout)
        self.assertIn(f"project's relay-orchestrator entry in {self.project}/.mcp.json", result.stderr)
        self.assertIn(f"Point it at {self.expected_mcp}", result.stderr)

    def test_project_entry_blocks_adding_a_shadowed_user_entry(self):
        (self.project / ".mcp.json").write_text(json.dumps({
            "mcpServers": {"relay-orchestrator": {"command": "/somewhere/else/server"}}
        }))
        result = self.register()
        self.assertIsNone(self.claude_entry("user"))
        self.assertIn(".mcp.json", result.stderr)

    def test_codex_project_config_shadowing_is_reported_not_fixed(self):
        (self.state / "codex-relay-orchestrator").write_text(str(self.expected_mcp))
        config = self.project / ".codex" / "config.toml"
        config.parent.mkdir()
        config.write_text(
            '[mcp_servers.relay-orchestrator]\n'
            f'command = "{OLD_MCP}"\n'
            'args = []\n'
        )
        result = self.register()
        self.assertNotIn("codex mcp add", self.log())
        self.assertNotIn("Codex MCP server", result.stdout)
        self.assertIn(f"project's relay-orchestrator entry in {config}", result.stderr)

    def test_customised_command_is_reported_not_overwritten(self):
        (self.state / "claude-user-relay-orchestrator").write_text("/usr/local/bin/my-wrapper")
        result = self.register()
        self.assertEqual(self.claude_entry("user"), "/usr/local/bin/my-wrapper")
        self.assertIn("left it unchanged", result.stderr)
        self.assertIn("mcp remove -s user relay-orchestrator", result.stderr)

    def test_relay_orchestrator_delegates_install_and_registration(self):
        self.install_script(
            "relay-orchestrator", (ROOT / "scripts" / "relay-orchestrator").read_text()
        )
        script = (self.scripts / "relay-orchestrator").read_text()
        self.assertIn(
            '"$SCRIPT_DIR/relay-bridge" --register-mcp \\\n'
            '        relay-orchestrator relay-orchestrator-mcp', script,
        )
        result = self.run_script("relay-orchestrator", "--install-skills")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.home / COMMAND_FILES["codex-dispatch"]).read_text(),
            load_build_instructions().command_file("relay-dispatch", "codex"),
        )


if __name__ == "__main__":
    unittest.main()
