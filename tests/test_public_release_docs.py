import plistlib
import re
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


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
        self.assertIn("docs/images/relay-runner-message-playing.png", readme)
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

    def test_screen_recording_copy_names_relay_vision(self):
        info = plistlib.loads((PROJECT_ROOT / "Info.plist").read_bytes())
        description = info["NSScreenCaptureUsageDescription"]
        self.assertIn("Relay Vision", description)
        self.assertNotIn("Relay Actions voice tools", description)


if __name__ == "__main__":
    unittest.main()
