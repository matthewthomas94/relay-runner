import importlib.metadata
import plistlib
import re
import unittest
from email.message import Message
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
INSTALLED_SERVICES_VENV = Path.home() / "Library/Application Support/relay-runner/services/.venv"
COPYLEFT = re.compile(
    r"GPL|General Public|MPL|Mozilla Public|EPL|Eclipse Public|CDDL|EUPL", re.IGNORECASE
)


def declares_copyleft(metadata):
    """True when a package's license metadata names a copyleft license."""
    declared = [metadata.get("License-Expression") or ""]
    declared.append((metadata.get("License") or "").strip().split("\n", 1)[0])
    declared.extend(
        value for value in metadata.get_all("Classifier") or [] if value.startswith("License ::")
    )
    return any(COPYLEFT.search(value) for value in declared)


class PublicReleaseDocumentationTests(unittest.TestCase):
    PUBLIC_MARKDOWN = (
        "README.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "SUPPORT.md",
        "CODE_OF_CONDUCT.md",
        "TESTING.md",
        "THIRD_PARTY_NOTICES.md",
        "docs/architecture.md",
        "docs/configuration.md",
        "docs/privacy.md",
        "docs/providers.md",
        "docs/repository-audit.md",
        "docs/troubleshooting.md",
        "docs/specs/relay-actions.md",
        "docs/specs/relay-desktop.md",
        "docs/specs/relay-vision.md",
    )

    def test_public_markdown_uses_existing_relative_targets(self):
        missing = []
        for relative in self.PUBLIC_MARKDOWN:
            document = PROJECT_ROOT / relative
            self.assertTrue(document.is_file(), relative)
            for target in re.findall(r"!?\[[^]]*\]\(([^)]+)\)", document.read_text()):
                target = target.strip().split("#", 1)[0].split("?", 1)[0]
                if not target or target.startswith(("http://", "https://", "mailto:")):
                    continue
                resolved = (document.parent / target).resolve()
                if not resolved.exists():
                    missing.append(f"{relative}: {target}")
        self.assertEqual(missing, [])

    def test_readme_has_sanitized_product_images_and_routes(self):
        readme = (PROJECT_ROOT / "README.md").read_text()
        self.assertIn("docs/images/relay-runner-demo.gif", readme)
        self.assertIn("docs/images/relay-runner-workspace.png", readme)
        self.assertNotIn("Permission is hereby granted", readme)
        for relative in (
            "LICENSE",
            "CONTRIBUTING.md",
            "SECURITY.md",
            "SUPPORT.md",
            "CODE_OF_CONDUCT.md",
            "TESTING.md",
            "THIRD_PARTY_NOTICES.md",
        ):
            self.assertTrue((PROJECT_ROOT / relative).is_file(), relative)

    def test_signed_release_requires_apple_silicon(self):
        readme = (PROJECT_ROOT / "README.md").read_text()
        requirement = "an Apple Silicon Mac running macOS 14 or later"
        self.assertIn(requirement, readme)
        self.assertNotIn("Apple Silicon is recommended", readme)

    def test_release_updates_identify_public_source_repository(self):
        release_updates = (PROJECT_ROOT / "docs/release-updates.md").read_text()
        self.assertIn("public source repository release", release_updates)
        self.assertNotIn("private source repo release", release_updates)

    def test_packaging_includes_license_notices(self):
        script = (PROJECT_ROOT / "scripts/build-dmg.sh").read_text()
        self.assertIn('cp "$PROJECT_ROOT/LICENSE"', script)
        self.assertIn('cp "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md"', script)
        self.assertIn("ThirdPartyLicenses", script)

    def test_notices_name_gpl_speech_dependencies(self):
        notices = (PROJECT_ROOT / "THIRD_PARTY_NOTICES.md").read_text()
        for name in ("espeak-ng", "espeakng-loader", "phonemizer-fork"):
            self.assertIn(name, notices)
        self.assertIn("GNU General Public License v3 or later", notices)
        self.assertIn("included in the signed app bundle", notices)

    def test_copyleft_detection_reads_license_metadata(self):
        def meta(**fields):
            message = Message()
            for key, value in fields.items():
                message[key.replace("_", "-")] = value
            return message

        self.assertTrue(declares_copyleft(meta(License_Expression="GPL-3.0-or-later")))
        self.assertTrue(declares_copyleft(meta(License="MPL-2.0 AND MIT")))
        self.assertTrue(declares_copyleft(meta(
            Classifier="License :: OSI Approved :: GNU Lesser General Public License v3 (LGPLv3)"
        )))
        self.assertFalse(declares_copyleft(meta(License_Expression="Apache-2.0 OR BSD-2-Clause")))
        self.assertFalse(declares_copyleft(meta(License="MIT License\n\nnot the GPL")))
        self.assertFalse(declares_copyleft(meta(Name="espeakng-loader")))

    def test_installed_voice_packages_with_copyleft_licenses_are_in_notices(self):
        # Scans environments that hold the resolved requirements: the one
        # running the tests, a repo-local venv and the installed services venv
        # (read-only). Wheels without license metadata cannot be detected.
        paths = [None]
        for venv in (PROJECT_ROOT / "services/.venv", INSTALLED_SERVICES_VENV):
            paths.extend([str(p)] for p in venv.glob("lib/python*/site-packages"))
        notices = (PROJECT_ROOT / "THIRD_PARTY_NOTICES.md").read_text().lower()
        scanned = False
        missing = set()
        for path in paths:
            found = list(
                importlib.metadata.distributions() if path is None
                else importlib.metadata.distributions(path=path)
            )
            names = {(d.metadata["Name"] or "").lower() for d in found}
            if "kokoro-onnx" not in names:
                continue
            scanned = True
            for dist in found:
                name = (dist.metadata["Name"] or "").lower()
                if declares_copyleft(dist.metadata) and name not in notices:
                    missing.add(f"{name}=={dist.version}")
        if not scanned:
            self.skipTest("services/requirements.txt is not installed in any known environment")
        self.assertEqual(sorted(missing), [])

    def test_screen_recording_copy_names_relay_vision(self):
        info = plistlib.loads((PROJECT_ROOT / "Info.plist").read_bytes())
        description = info["NSScreenCaptureUsageDescription"]
        self.assertIn("Relay Vision", description)
        self.assertNotIn("Relay Actions voice tools", description)


if __name__ == "__main__":
    unittest.main()
