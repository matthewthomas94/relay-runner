from __future__ import annotations

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
    RELEASE_REQUIREMENT,
    resolve_signing_identity,
    verify_update_identity,
)


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


if __name__ == "__main__":
    unittest.main()
