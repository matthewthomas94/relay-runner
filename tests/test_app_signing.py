from __future__ import annotations

import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))

from app_signing import (  # noqa: E402
    AppSigningError,
    POWER_HELPER_LABEL,
    POWER_HELPER_PLIST,
    POWER_HELPER_PROGRAM,
    POWER_HELPER_REQUIREMENT,
    RELEASE_REQUIREMENT,
    SIGNING_TEAM,
    check_power_helper,
    resolve_signing_identity,
    verify_update_identity,
)

SOURCE_PLIST = ROOT / "scripts" / "LaunchDaemons" / f"{POWER_HELPER_LABEL}.plist"
SWIFT_IDENTITY = ROOT / "Sources" / "RelayPowerHelperProtocol" / "RelayPowerHelper.swift"


def make_bundle(directory: str, job: dict | None = None, executable: bool = True) -> Path:
    app = Path(directory) / "Relay Runner.app"
    (app / POWER_HELPER_PLIST).parent.mkdir(parents=True)
    (app / POWER_HELPER_PROGRAM).parent.mkdir(parents=True)
    if job is None:
        job = plistlib.loads(SOURCE_PLIST.read_bytes())
    (app / POWER_HELPER_PLIST).write_bytes(plistlib.dumps(job))
    helper = app / POWER_HELPER_PROGRAM
    helper.write_bytes(b"\xcf\xfa\xed\xfe")
    os.chmod(helper, 0o755 if executable else 0o644)
    return app


def result(stdout="", stderr="", code=0):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class AppSigningTests(unittest.TestCase):
    @mock.patch("app_signing.subprocess.run")
    def test_default_chooses_release_team_developer_id_over_development_or_other_team(self, run):
        run.return_value = result(
            '  1) ' + 'A' * 40 + ' "Apple Development: Developer (QK9K4AQRNH)"\n'
            '  2) ' + 'B' * 40 + ' "Developer ID Application: Other (OTHERTEAM1)"\n'
            '  3) ' + 'C' * 40 + ' "Developer ID Application: Relay (QK9K4AQRNH)"\n'
        )
        self.assertEqual(resolve_signing_identity(), 'C' * 40)

    @mock.patch("app_signing.subprocess.run")
    def test_missing_or_inaccessible_identity_never_silently_falls_back_to_adhoc(self, run):
        for response in (result("0 valid identities found"), result(code=1)):
            run.return_value = response
            with self.assertRaisesRegex(AppSigningError, "cannot preserve macOS permissions"):
                resolve_signing_identity()

    @mock.patch("app_signing.subprocess.run")
    def test_isolated_ci_artifacts_can_explicitly_allow_adhoc(self, run):
        run.return_value = result("0 valid identities found")
        self.assertEqual(resolve_signing_identity(allow_adhoc=True), "")
        self.assertEqual(resolve_signing_identity("-", allow_adhoc=True), "")
        with self.assertRaises(AppSigningError):
            resolve_signing_identity("-")

    @mock.patch("app_signing.subprocess.run")
    def test_explicit_certificate_is_used_and_verified_when_bundle_is_signed(self, run):
        self.assertEqual(resolve_signing_identity("selected certificate"), "selected certificate")
        run.assert_not_called()

    @mock.patch("app_signing.subprocess.run")
    def test_replacement_must_satisfy_the_previous_requirement_not_match_its_text(self, run):
        with tempfile.TemporaryDirectory() as directory:
            installed = Path(directory)
            source = installed / "new.app"
            previous_requirement = 'identifier "com.relayrunner.app" and anchor apple generic'
            run.side_effect = [
                result(),
                result('designated => ' + previous_requirement + '\n', 'TeamIdentifier=QK9K4AQRNH'),
                result(),
            ]
            verify_update_identity(source, installed)
            checks = [call.args[0] for call in run.call_args_list]
            self.assertIn("=" + RELEASE_REQUIREMENT, checks[0])
            self.assertIn("=" + previous_requirement, checks[2])

    @mock.patch("app_signing.subprocess.run")
    def test_unsigned_adhoc_damaged_or_other_team_source_is_rejected_before_replacement(self, run):
        run.return_value = result(code=1, stderr="code failed to satisfy specified code requirement")
        with self.assertRaisesRegex(AppSigningError, "valid Developer ID signature"):
            verify_update_identity(Path("new.app"))
        self.assertEqual(run.call_count, 1)

    @mock.patch("app_signing.subprocess.run")
    def test_incompatible_or_unreadable_previous_identity_blocks_replacement(self, run):
        with tempfile.TemporaryDirectory() as directory:
            for previous, compatible in (
                (result(code=1), []),
                (result("no requirement"), []),
                (result("designated => old requirement\n"), [result(code=1)]),
            ):
                run.side_effect = [result(), previous, *compatible]
                with self.assertRaisesRegex(AppSigningError, "keeping it in place"):
                    verify_update_identity(Path("new.app"), Path(directory))

    @mock.patch("app_signing.subprocess.run")
    def test_old_adhoc_install_can_migrate_to_verified_developer_id(self, run):
        with tempfile.TemporaryDirectory() as directory:
            run.side_effect = [result(), result(stderr="Signature=adhoc\n")]
            with mock.patch("app_signing.sys.stderr"):
                verify_update_identity(Path("new.app"), Path(directory))
            self.assertEqual(run.call_count, 2)


class PowerHelperPackagingTests(unittest.TestCase):
    def test_source_plist_matches_the_identifiers_compiled_into_app_and_helper(self):
        swift = SWIFT_IDENTITY.read_text()
        self.assertIn(f'label = "{POWER_HELPER_LABEL}"', swift)
        self.assertIn(f'teamIdentifier = "{SIGNING_TEAM}"', swift)
        self.assertIn('appIdentifier = "com.relayrunner.app"', swift)
        self.assertIn('executableName = "relay-power-helper"', swift)
        # The Swift requirement template is the same Developer ID requirement as the app's.
        template = re.search(r'"identifier \\"\\\(identifier\)\\" and anchor apple generic "\s*\+ "(.*?)"\s*\+ "(.*?)"\s*\+ "and certificate leaf\[subject.OU\]', swift, re.S)
        self.assertIsNotNone(template)
        self.assertIn(template.group(1).strip(), RELEASE_REQUIREMENT)
        self.assertIn(template.group(2).strip(), RELEASE_REQUIREMENT)
        self.assertEqual(POWER_HELPER_REQUIREMENT, RELEASE_REQUIREMENT.replace(
            'identifier "com.relayrunner.app"', f'identifier "{POWER_HELPER_LABEL}"'))
        with tempfile.TemporaryDirectory() as directory:
            check_power_helper(make_bundle(directory))

    def test_build_embeds_signs_and_checks_the_helper(self):
        script = (ROOT / "scripts" / "build-dmg.sh").read_text()
        self.assertIn('cp "$BUILD_DIR/relay-power-helper" "$APP_DIR/Contents/MacOS/relay-power-helper"', script)
        self.assertIn(f"scripts/LaunchDaemons/{POWER_HELPER_LABEL}.plist", script)
        self.assertIn('"$APP_DIR/Contents/Library/LaunchDaemons"', script)
        self.assertIn(f"--identifier {POWER_HELPER_LABEL}", script)
        self.assertIn("check-helper", script)
        self.assertIn("relay-remote-shell relay-power-helper; do", script, "The helper keeps matching dSYMs")
        # Nested code is signed before the app bundle's seal.
        self.assertLess(script.index(f"--identifier {POWER_HELPER_LABEL}"), script.index('"$APP_DIR"\nelse'))

    def test_mismatched_or_permissive_launchd_metadata_is_rejected(self):
        base = plistlib.loads(SOURCE_PLIST.read_bytes())
        variants = [
            {**base, "Label": "com.example.other"},
            {**base, "MachServices": {"com.example.other": True}},
            {**base, "BundleProgram": "Contents/MacOS/relay-runner"},
            {**base, "ProgramArguments": ["/bin/sh", "-c", "id"]},
            {**base, "AssociatedBundleIdentifiers": ["com.example.other"]},
            {**base, "KeepAlive": True},
        ]
        for job in variants:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(AppSigningError, "does not match"):
                    check_power_helper(make_bundle(directory, job))

    def test_missing_or_non_executable_helper_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = make_bundle(directory, executable=False)
            with self.assertRaisesRegex(AppSigningError, "missing"):
                check_power_helper(app)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(AppSigningError, "plist is missing"):
                check_power_helper(Path(directory) / "Empty.app")

    @mock.patch("app_signing.subprocess.run")
    def test_signed_build_requires_the_helpers_developer_id_identity(self, run):
        with tempfile.TemporaryDirectory() as directory:
            app = make_bundle(directory)
            run.return_value = result()
            check_power_helper(app, signed=True)
            self.assertIn("=" + POWER_HELPER_REQUIREMENT, run.call_args.args[0])
            self.assertEqual(run.call_args.args[0][-1], str(app / POWER_HELPER_PROGRAM))
            run.return_value = result(code=1, stderr="code failed to satisfy specified code requirement")
            with self.assertRaisesRegex(AppSigningError, "would refuse it"):
                check_power_helper(app, signed=True)

    @mock.patch("app_signing.subprocess.run")
    def test_unsigned_structural_check_never_runs_codesign(self, run):
        with tempfile.TemporaryDirectory() as directory:
            check_power_helper(make_bundle(directory))
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
