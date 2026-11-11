from __future__ import annotations

import os
import plistlib
import re
import shutil
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
    RUST_HELPER_PROGRAM,
    RUST_HELPER_REQUIREMENT,
    SIGNING_TEAM,
    check_power_helper,
    check_rust_helper,
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


def make_rust_bundle(directory: str, reports: str = "relay-rs 1.2.3 (45)") -> Path:
    app = Path(directory) / "Relay Runner.app"
    helper = app / RUST_HELPER_PROGRAM
    helper.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(
        plistlib.dumps({"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"}))
    helper.write_text(f'#!/bin/sh\n[ "$1" = --version ] && echo "{reports}"\n')
    os.chmod(helper, 0o755)
    return app


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


class RustHelperPackagingTests(unittest.TestCase):
    def test_build_checks_toolchain_then_builds_embeds_and_signs_the_helper(self):
        script = (ROOT / "scripts" / "build-dmg.sh").read_text()
        build = '(cd "$RUST_DIR" && cargo build --release --locked --target "$RUST_TARGET")'
        copy = 'cp "$RUST_DIR/target/$RUST_TARGET/release/relay-rs" "$APP_DIR/Contents/MacOS/relay-rs"'
        self.assertIn('RUST_TARGET="aarch64-apple-darwin"', script)
        # The toolchain is checked before anything is built, and the helper is
        # signed with the other helpers before the app bundle's seal.
        self.assertLess(script.index("Rust toolchain not found"), script.index("swift build"))
        self.assertLess(script.index("swift build"), script.index(build))
        self.assertLess(script.index(build), script.index(copy))
        signed = re.findall(
            r'codesign --force --timestamp --options runtime \\\n\s+--sign "\$SIGN_IDENTITY" \\\n'
            r'\s+"\$APP_DIR/Contents/MacOS/([^"]+)"', script)
        self.assertIn("relay-rs", signed)
        self.assertIn("agent-desktop", signed, "relay-rs is signed exactly like the bundled Rust precedent")
        self.assertLess(script.index('"$APP_DIR/Contents/MacOS/relay-rs"\n    # The power'), script.index('"$APP_DIR"\nelse'))
        self.assertLess(script.index('"$APP_DIR"\nelse'), script.index('app_signing.py" check-helper'))

    def test_build_without_a_rust_toolchain_stops_before_building_and_names_the_install(self):
        if shutil.which("cargo", path="/usr/bin:/bin") or shutil.which("rustc", path="/usr/bin:/bin"):
            self.skipTest("a system Rust toolchain is installed")
        with tempfile.TemporaryDirectory() as directory:
            # A stand-in `swift` proves the script stopped before the build.
            swift = Path(directory) / "swift"
            swift.write_text("#!/bin/sh\necho swift-was-run >&2\nexit 99\n")
            os.chmod(swift, 0o755)
            run = subprocess.run(
                ["/bin/bash", str(ROOT / "scripts" / "build-dmg.sh"), "--app-only"],
                env={"HOME": directory, "PATH": f"{directory}:/usr/bin:/bin",
                     "SIGN_IDENTITY": "-", "RELAY_ALLOW_ADHOC_SIGNING": "1"},
                capture_output=True, text=True,
            )
        self.assertEqual(run.returncode, 1, run.stderr)
        self.assertIn("Rust toolchain not found", run.stderr)
        self.assertIn("https://sh.rustup.rs", run.stderr)
        self.assertNotIn("swift-was-run", run.stderr)
        self.assertEqual(run.stdout, "")

    def test_helper_must_be_packaged_and_report_the_bundle_version(self):
        with tempfile.TemporaryDirectory() as directory:
            check_rust_helper(make_rust_bundle(directory))
        for reports in ("relay-rs 1.2.3 (44)", "relay-rs 1.2.2 (45)", ""):
            with self.subTest(reports=reports), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(AppSigningError, "not the bundle's 'relay-rs 1.2.3 \\(45\\)'"):
                    check_rust_helper(make_rust_bundle(directory, reports))
        with tempfile.TemporaryDirectory() as directory:
            app = make_rust_bundle(directory)
            os.chmod(app / RUST_HELPER_PROGRAM, 0o644)
            with self.assertRaisesRegex(AppSigningError, "missing"):
                check_rust_helper(app)
        with tempfile.TemporaryDirectory() as directory:
            app = make_rust_bundle(directory)
            (app / "Contents/Info.plist").unlink()
            with self.assertRaisesRegex(AppSigningError, "Info.plist"):
                check_rust_helper(app)

    @mock.patch("app_signing.subprocess.run")
    def test_signed_build_requires_the_rust_helpers_developer_id_identity(self, run):
        self.assertEqual(RUST_HELPER_REQUIREMENT, RELEASE_REQUIREMENT.replace(
            'identifier "com.relayrunner.app"', 'identifier "relay-rs"'))
        with tempfile.TemporaryDirectory() as directory:
            app = make_rust_bundle(directory)
            run.side_effect = [result("relay-rs 1.2.3 (45)\n"), result()]
            check_rust_helper(app, signed=True)
            self.assertEqual(run.call_args_list[0].args[0], [str(app / RUST_HELPER_PROGRAM), "--version"])
            self.assertIn("=" + RUST_HELPER_REQUIREMENT, run.call_args.args[0])
            self.assertEqual(run.call_args.args[0][-1], str(app / RUST_HELPER_PROGRAM))
            run.side_effect = [
                result("relay-rs 1.2.3 (45)\n"),
                result(code=1, stderr="code failed to satisfy specified code requirement"),
            ]
            with self.assertRaisesRegex(AppSigningError, "not signed as relay-rs"):
                check_rust_helper(app, signed=True)


if __name__ == "__main__":
    unittest.main()
