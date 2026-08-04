import hashlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from services.artifact_verification import (
    INSTALLED_SCENARIOS,
    PROVIDER_DIFFERENCE_IDS,
    ArtifactVerificationError,
    RR289SourceVerificationHarness,
    SignedInstalledAppGate,
)


class ArtifactVerificationTests(unittest.TestCase):
    def test_installed_direct_script_layout_imports_without_package_parent(self):
        root = Path(__file__).resolve().parents[1]
        for script in (
            root / "services/artifact_verification_cli.py",
            root / "services/artifact_rollout_cli.py",
        ):
            result = subprocess.run(
                [sys.executable, str(script), "--help"],
                cwd=Path(tempfile.gettempdir()),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_installed_harness_requires_external_source_report_without_shipping_tests(self):
        with tempfile.TemporaryDirectory(prefix="relay-installed-matrix-") as directory:
            status = RR289SourceVerificationHarness.source_matrix_status(Path(directory))
        self.assertTrue(status)
        self.assertEqual(set(status.values()), {"external_source_report_required"})

    def test_disposable_two_device_harness_proves_sync_conflict_failure_and_provider_invariants(self):
        report = RR289SourceVerificationHarness().run()
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["device_count"], 2)
        self.assertTrue(report["scenarios"]["unrelated_offline_edits"]["source_state_unchanged"])
        self.assertTrue(report["scenarios"]["same_ticket"]["publication_stopped"])
        self.assertTrue(report["scenarios"]["config_collision"]["publication_stopped"])
        self.assertTrue(report["scenarios"]["attachment_collision"]["publication_stopped"])
        self.assertFalse(report["scenarios"]["push_race"]["force_push"])
        self.assertEqual(
            report["scenarios"]["provider_parity"]["providers"],
            ["codex", "claude"],
        )
        self.assertRegex(report["report_sha256"], r"^[0-9a-f]{64}$")

    def test_signed_installed_gate_accepts_two_device_complete_bounded_evidence(self):
        with tempfile.TemporaryDirectory(prefix="relay-installed-gate-") as directory:
            app = self.make_app(Path(directory))
            gate = SignedInstalledAppGate(runner=self.signed_runner)
            identity = gate.inspect(app, require_applications=False)
            evidence = gate.evidence_template(identity)
            scenarios = sorted(INSTALLED_SCENARIOS)
            midpoint = len(scenarios) // 2
            evidence["devices"] = [
                self.device("device-a", scenarios[:midpoint], {"codex": "passed"}),
                self.device("device-b", scenarios[midpoint:], {"claude": "passed"}),
            ]

            result = gate.evaluate(identity, evidence)

            self.assertEqual(result["status"], "passed")
            self.assertEqual(result["device_count"], 2)
            self.assertEqual(result["scenario_count"], len(INSTALLED_SCENARIOS))
            self.assertEqual(result["providers"], ["claude", "codex"])
            self.assertEqual(result["blocker_codes"], [])

    def test_installed_gate_stays_verification_blocked_for_one_device_missing_scenarios_and_provider(self):
        with tempfile.TemporaryDirectory(prefix="relay-installed-blocked-") as directory:
            app = self.make_app(Path(directory))
            gate = SignedInstalledAppGate(runner=self.signed_runner)
            identity = gate.inspect(app, require_applications=False)
            evidence = gate.evidence_template(identity)
            evidence["devices"] = [
                self.device("only-device", ["empty_workspace"], {"codex": "passed"})
            ]

            result = gate.evaluate(identity, evidence)

            self.assertEqual(result["status"], "verification_blocked")
            self.assertIn("two_distinct_devices_required", result["blocker_codes"])
            self.assertIn("installed_provider_parity_required", result["blocker_codes"])
            self.assertIn("scenario_missing:mounted_workspace", result["blocker_codes"])
            self.assertIn("two devices", result["resume_condition"])

    def test_installed_gate_rejects_ad_hoc_signature_and_unbounded_evidence(self):
        with tempfile.TemporaryDirectory(prefix="relay-installed-adhoc-") as directory:
            app = self.make_app(Path(directory))

            def adhoc(command):
                if "-dv" in command:
                    return subprocess.CompletedProcess(command, 0, b"", b"TeamIdentifier=not set\nSignature=adhoc\n")
                return subprocess.CompletedProcess(command, 0, b"", b"")

            with self.assertRaisesRegex(ArtifactVerificationError, "Developer ID signed"):
                SignedInstalledAppGate(runner=adhoc).inspect(app, require_applications=False)

            identity = SignedInstalledAppGate(runner=self.signed_runner).inspect(
                app, require_applications=False
            )
            evidence = SignedInstalledAppGate.evidence_template(identity)
            evidence["raw_log"] = "private"
            with self.assertRaisesRegex(ArtifactVerificationError, "unsupported shape"):
                SignedInstalledAppGate(runner=self.signed_runner).evaluate(identity, evidence)

    def test_installed_gate_rejects_non_developer_id_certificate_with_team_id(self):
        with tempfile.TemporaryDirectory(prefix="relay-installed-certificate-") as directory:
            app = self.make_app(Path(directory))

            def development_runner(command):
                if "-dv" in command:
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        b"",
                        (
                            b"TeamIdentifier=TEAM123\n"
                            b"Signature size=9000\n"
                            b"Authority=Apple Development: Local Developer (TEAM123)\n"
                        ),
                    )
                return subprocess.CompletedProcess(command, 0, b"", b"")

            with self.assertRaisesRegex(ArtifactVerificationError, "Developer ID signed"):
                SignedInstalledAppGate(runner=development_runner).inspect(
                    app,
                    require_applications=False,
                )

    @staticmethod
    def make_app(root: Path) -> Path:
        app = root / "Relay Runner.app"
        contents = app / "Contents"
        executable = contents / "MacOS/relay-runner"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"reviewed executable")
        info = {
            "CFBundleShortVersionString": "0.4.99",
            "CFBundleVersion": "99",
            "CFBundleIdentifier": "com.relayrunner.app",
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        return app

    @staticmethod
    def signed_runner(command):
        if "-dv" in command:
            return subprocess.CompletedProcess(
                command,
                0,
                b"",
                b"TeamIdentifier=TEAM123\nSignature size=9000\nAuthority=Developer ID Application\n",
            )
        return subprocess.CompletedProcess(command, 0, b"", b"")

    @staticmethod
    def device(name, scenarios, providers):
        return {
            "device_id_sha256": hashlib.sha256(name.encode()).hexdigest(),
            "os_version": "macOS-15.6",
            "scenarios": {scenario: "passed" for scenario in scenarios},
            "providers": providers,
            "evidence_sha256": hashlib.sha256((name + "-evidence").encode()).hexdigest(),
        }


if __name__ == "__main__":
    unittest.main()
