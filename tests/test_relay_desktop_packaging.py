"""Relay Desktop packaging: the pinned agent-desktop release ships inside the app."""

import os
import re
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = (ROOT / "scripts/build-dmg.sh").read_text()
FETCH_SCRIPT = (ROOT / "scripts/fetch-agent-desktop.sh").read_text()


class RelayDesktopPackagingTests(unittest.TestCase):
    def test_fetch_script_pins_version_archives_and_license(self):
        self.assertRegex(FETCH_SCRIPT, r'AGENT_DESKTOP_VERSION="\d+\.\d+\.\d+"')
        for name in ("AARCH64", "X86_64"):
            self.assertRegex(FETCH_SCRIPT, rf'AGENT_DESKTOP_SHA256_{name}="[0-9a-f]{{64}}"')
        self.assertRegex(FETCH_SCRIPT, r'AGENT_DESKTOP_LICENSE_SHA256="[0-9a-f]{64}"')
        # Verification happens before extraction, never after.
        self.assertLess(FETCH_SCRIPT.index('verify_sha256 "$ARCHIVE_PATH"'), FETCH_SCRIPT.index("tar -xzf"))
        self.assertLess(FETCH_SCRIPT.index('verify_sha256 "$CACHE_DIR/LICENSE"'), FETCH_SCRIPT.index("tar -xzf"))
        self.assertIn("releases/download/v${AGENT_DESKTOP_VERSION}/", FETCH_SCRIPT)

    def test_fetch_script_refuses_an_archive_that_does_not_match_the_pin(self):
        with tempfile.TemporaryDirectory() as tmp:
            bogus = Path(tmp) / "bogus.tar.gz"
            payload = Path(tmp) / "agent-desktop"
            payload.write_text("#!/bin/sh\necho tampered\n")
            with tarfile.open(bogus, "w:gz") as archive:
                archive.add(payload, arcname="agent-desktop")
            cache = Path(tmp) / "cache"
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/fetch-agent-desktop.sh")],
                env={**os.environ, "AGENT_DESKTOP_ARCHIVE": str(bogus), "AGENT_DESKTOP_CACHE_DIR": str(cache)},
                cwd=ROOT,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("checksum mismatch", result.stderr)
            self.assertEqual(result.stdout.strip(), "")
            self.assertEqual(list(cache.rglob("agent-desktop")), [])
            self.assertEqual(list(cache.rglob(".verified")), [])

    def test_build_embeds_signs_and_licenses_the_bundled_cli(self):
        self.assertIn('AGENT_DESKTOP_DIR="$("$SCRIPT_DIR/fetch-agent-desktop.sh")"', BUILD_SCRIPT)
        for binary in ("agent-desktop", "agent-desktop-macos-helper"):
            self.assertIn(f'cp "$AGENT_DESKTOP_DIR/{binary}" "$APP_DIR/Contents/MacOS/{binary}"', BUILD_SCRIPT)
            self.assertIn(f'"$APP_DIR/Contents/MacOS/{binary}"\n', BUILD_SCRIPT.split("codesign --force --timestamp --options runtime", 1)[1])
        self.assertIn('cp "$BUILD_DIR/relay-desktop-mcp" "$APP_DIR/Contents/MacOS/relay-desktop-mcp"', BUILD_SCRIPT)
        self.assertIn('cp "$AGENT_DESKTOP_DIR/LICENSE" "$THIRD_PARTY_LICENSES_DIR/agent-desktop.txt"', BUILD_SCRIPT)
        dsym_list = re.search(r"for binary in (.+); do\n\s+binary_path=", BUILD_SCRIPT).group(1).split()
        self.assertIn("relay-desktop-mcp", dsym_list)
        # Downloaded Rust binaries are stripped; they never enter the dSYM contract.
        self.assertNotIn("agent-desktop", dsym_list)
        signed = re.findall(r'--sign "\$SIGN_IDENTITY" \\\n\s+"\$APP_DIR/Contents/MacOS/([^"]+)"', BUILD_SCRIPT)
        for binary in ("relay-desktop-mcp", "agent-desktop", "agent-desktop-macos-helper"):
            self.assertIn(binary, signed)

    def test_relay_desktop_is_registered_probed_and_built(self):
        bridge = (ROOT / "scripts/relay-bridge").read_text()
        self.assertIn("available_agents_have_mcp relay-desktop relay-desktop-mcp", bridge)
        self.assertIn('register_mcp_for_available_agents relay-desktop relay-desktop-mcp "Relay Desktop"', bridge)
        self.assertIn('"relay-desktop-mcp",', (ROOT / "scripts/mcp-lifecycle-probe.py").read_text())
        package = (ROOT / "Package.swift").read_text()
        self.assertIn('name: "relay-desktop-mcp"', package)
        self.assertIn('.target(name: "relay-desktop-mcp")', package)
        self.assertIn("agent-desktop", (ROOT / "THIRD_PARTY_NOTICES.md").read_text())


if __name__ == "__main__":
    unittest.main()
