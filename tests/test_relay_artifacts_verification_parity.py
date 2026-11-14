"""RR-495: services/artifact_verification.py against relay_artifacts::verification.

Each case calls the same public entry point through the Python module
in-process and through the relay-artifacts test driver, and compares the
answers: the source-matrix audit and status (present, external report
required, a missing file and changed coverage), the signed installed-app
gate's `inspect` over bundles and canned `codesign` results (Developer ID,
ad hoc, development certificates, failed verification, wrong identifier,
missing, text, XML and binary property lists, the /Applications
requirement), `evaluate` over complete, blocked and malformed evidence
manifests, `evidence_template`, the bundle digest over files, directories
and symlinks, and the RR-289 disposable two-device source harness report
with its `report_sha256`. A refusal is compared by class, message, `code`
and `recovery`.

Rust cases skip when the crate's test driver is not built (``cargo test`` in
rust/ builds it); see tests/relay_artifacts_support.py.
"""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from relay_artifacts_support import REPO, RustArtifacts, driver_command  # noqa: E402

from services import artifact_verification  # noqa: E402
from services.artifact_verification import (  # noqa: E402
    INSTALLED_SCENARIOS,
    PROVIDER_DIFFERENCE_IDS,
    SOURCE_MATRIX,
    InstalledBundleIdentity,
    RR289SourceVerificationHarness,
    SignedInstalledAppGate,
)

SIGNED = "TeamIdentifier=TEAM123\nSignature size=9000\nAuthority=Developer ID Application\n"
RUNNERS = {
    "signed": {"verify": {"returncode": 0}, "details": {"returncode": 0, "stderr": SIGNED}},
    "signed_named": {"verify": {"returncode": 0}, "details": {
        "returncode": 0, "stdout": "Authority=Developer ID Application: Relay (TEAM123)\n",
        "stderr": "TeamIdentifier=TEAM123\nSignature size=9000\n"}},
    "adhoc": {"verify": {"returncode": 0}, "details": {
        "returncode": 0, "stderr": "TeamIdentifier=not set\nSignature=adhoc\n"}},
    "development": {"verify": {"returncode": 0}, "details": {"returncode": 0, "stderr": (
        "TeamIdentifier=TEAM123\nSignature size=9000\n"
        "Authority=Apple Development: Local Developer (TEAM123)\n")}},
    "verify_failed": {"verify": {"returncode": 1, "stderr": "invalid signature"},
                      "details": {"returncode": 0, "stderr": SIGNED}},
    "details_failed": {"verify": {"returncode": 0}, "details": {"returncode": 1, "stderr": SIGNED}},
}


def jsonable(value):
    return json.loads(json.dumps(value))


class PythonVerification:
    """The Python module, answering as the driver's `verification.*` ops do."""

    def call(self, op: str, **a):
        function = op.split(".", 1)[1]
        try:
            return jsonable(self._call(function, a))
        except Exception as error:  # noqa: BLE001 - compared with the Rust class
            # An OSError subclass reports as OSError, as everywhere in the crate.
            name = "OSError" if isinstance(error, OSError) else type(error).__name__
            return {"$error": name, "message": str(error),
                    "code": getattr(error, "code", None), "recovery": getattr(error, "recovery", None)}

    @staticmethod
    def _gate(a: dict) -> SignedInstalledAppGate:
        runner = a.get("runner")
        if not runner:
            return SignedInstalledAppGate()

        def canned(command):
            spec = runner["details"] if "-dv" in command else runner["verify"]
            return subprocess.CompletedProcess(
                command, spec.get("returncode", 0), spec.get("stdout", "").encode(),
                spec.get("stderr", "").encode())

        return SignedInstalledAppGate(runner=canned)

    def _call(self, function: str, a: dict):
        harness = RR289SourceVerificationHarness
        if function == "run":
            return harness(git_binary=a.get("git_binary", "git")).run()
        if function == "source_matrix_status":
            return harness.source_matrix_status(Path(a["root"]))
        if function == "audit_source_matrix":
            return harness.audit_source_matrix(Path(a["root"]))
        if function == "inspect":
            return self._gate(a).inspect(
                a["app"], require_applications=a.get("require_applications", True)).as_dict()
        if function == "evaluate":
            return self._gate(a).evaluate(InstalledBundleIdentity(**a["identity"]), a["evidence"])
        if function == "evidence_template":
            return SignedInstalledAppGate.evidence_template(InstalledBundleIdentity(**a["identity"]))
        if function == "bundle_digest":
            return SignedInstalledAppGate._bundle_digest(Path(a["app"]).resolve())
        raise TypeError("unknown operation")


def make_app(root: Path, name: str = "Relay Runner.app", *, info=None, info_bytes=None) -> Path:
    app = root / name
    executable = app / "Contents/MacOS/relay-runner"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"reviewed executable")
    plist = app / "Contents/Info.plist"
    if info_bytes is not None:
        plist.write_bytes(info_bytes)
    elif info is not False:
        plist.write_bytes(plistlib.dumps(info or {
            "CFBundleShortVersionString": "0.4.99", "CFBundleVersion": "99",
            "CFBundleIdentifier": "com.relayrunner.app"}))
    return app


def device(name: str, scenarios, providers, **changes) -> dict:
    value = {
        "device_id_sha256": hashlib.sha256(name.encode()).hexdigest(),
        "os_version": "macOS-15.6",
        "scenarios": {scenario: "passed" for scenario in scenarios},
        "providers": providers,
        "evidence_sha256": hashlib.sha256((name + "-evidence").encode()).hexdigest(),
    }
    value.update(changes)
    return value


@unittest.skipUnless(driver_command(), "relay-artifacts driver is not built; run cargo test in rust/")
class VerificationParityTest(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-verification-parity-")
        self.root = Path(self.temporary.name).resolve()
        self.addCleanup(self.temporary.cleanup)
        self.python = PythonVerification()
        self.rust = RustArtifacts(driver_command())
        self.addCleanup(self.rust.close)

    def assertSame(self, op: str, **arguments):
        python = self.python.call(op, **arguments)
        rust = self.rust.call(op, **arguments)
        self.assertEqual(rust, python, "%s %s" % (op, json.dumps(arguments, default=str)[:300]))
        return python

    def test_source_matrix(self):
        tampered = self.root / "tampered"
        for relative, *_needles in SOURCE_MATRIX.values():
            target = tampered / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / relative, target)
        missing = self.root / "missing"
        shutil.copytree(tampered, missing)
        first_file = next(iter(SOURCE_MATRIX.values()))[0]
        (missing / first_file).unlink()
        changed = self.root / "changed"
        shutil.copytree(tampered, changed)
        relative, needle = next(iter(SOURCE_MATRIX.values()))[:2]
        path = changed / relative
        path.write_text(path.read_text().replace(needle, "renamed"))
        empty = self.root / "empty"
        empty.mkdir()
        for root in (REPO, tampered, missing, changed, empty, self.root / "absent"):
            with self.subTest(root=root.name):
                for op in ("verification.source_matrix_status", "verification.audit_source_matrix"):
                    self.assertSame(op, root=str(root))
        self.assertEqual(set(self.python.call("verification.source_matrix_status", root=str(REPO)).values()),
                         {"present"})

    def test_inspect_bundles_and_signatures(self):
        bundles = {
            "plain": make_app(self.root / "plain"),
            "binary": make_app(self.root / "binary", info_bytes=plistlib.dumps({
                "CFBundleShortVersionString": "1.2", "CFBundleVersion": 7,
                "CFBundleIdentifier": "com.relayrunner.app"}, fmt=plistlib.FMT_BINARY)),
            "wrong_id": make_app(self.root / "wrong", info={"CFBundleIdentifier": "com.example"}),
            "no_plist": make_app(self.root / "none", info=False),
            "text_plist": make_app(self.root / "text", info_bytes=b"not a property list"),
            "empty_values": make_app(self.root / "empty", info={
                "CFBundleIdentifier": "com.relayrunner.app", "CFBundleVersion": ""}),
        }
        for name, app in bundles.items():
            for runner_name, runner in RUNNERS.items():
                for require in (False, True):
                    with self.subTest(bundle=name, runner=runner_name, require=require):
                        self.assertSame("verification.inspect", app=str(app), runner=runner,
                                        require_applications=require)
        self.assertSame("verification.inspect", app=str(self.root / "absent.app"),
                        runner=RUNNERS["signed"], require_applications=False)
        identity = self.python.call("verification.inspect", app=str(bundles["plain"]),
                                    runner=RUNNERS["signed"], require_applications=False)
        self.assertTrue(identity["developer_id_signed"])

    def test_bundle_digest(self):
        app = make_app(self.root / "digest")
        (app / "Contents/Resources/nested/deeper").mkdir(parents=True)
        (app / "Contents/Resources/nested/a.txt").write_text("a")
        (app / "Contents/Resources/é.txt").write_text("unicode name")
        os.symlink("../MacOS/relay-runner", app / "Contents/Resources/link")
        os.symlink("missing-target", app / "Contents/Resources/dangling")
        self.assertSame("verification.bundle_digest", app=str(app))
        empty = self.root / "Empty.app"
        empty.mkdir()
        self.assertSame("verification.bundle_digest", app=str(empty))
        os.mkfifo(app / "Contents/pipe")
        self.assertSame("verification.bundle_digest", app=str(app))

    def test_evaluate_evidence(self):
        app = make_app(self.root / "evaluate")
        identity = self.python.call("verification.inspect", app=str(app), runner=RUNNERS["signed"],
                                    require_applications=False)
        template = self.assertSame("verification.evidence_template", identity=identity)
        scenarios = sorted(INSTALLED_SCENARIOS)
        half = len(scenarios) // 2
        complete = dict(template, devices=[
            device("device-a", scenarios[:half], {"codex": "passed"}),
            device("device-b", scenarios[half:], {"claude": "passed"}),
        ])

        def variant(**changes):
            return {**json.loads(json.dumps(complete)), **changes}

        cases = {
            "complete": complete,
            "template": template,
            "one_device": variant(devices=[device("only", ["empty_workspace"], {"codex": "passed"})]),
            "failed_outcomes": variant(devices=[
                device("device-a", scenarios, {"codex": "failed", "claude": "passed"}),
                dict(device("device-b", [], {"claude": "passed"}), scenarios={scenarios[0]: "failed"}),
            ]),
            "same_device_twice": variant(devices=[device("same", scenarios, {"codex": "passed"}),
                                                  device("same", scenarios, {"claude": "passed"})]),
            "bundle_mismatch": variant(bundle=dict(template["bundle"], build_number="100")),
            "differences_incomplete": variant(
                intentional_provider_differences=sorted(PROVIDER_DIFFERENCE_IDS)[:1]),
            "extra_key": variant(raw_log="private"),
            "schema": variant(schema_version=2),
            "bundle_incomplete": variant(bundle={"version": "0.4.99"}),
            "bundle_not_dict": variant(bundle=["x"]),
            "devices_not_list": variant(devices={}),
            "too_many_devices": variant(devices=[device(f"d{n}", [], {}) for n in range(9)]),
            "device_extra_field": variant(devices=[dict(device("a", [], {}), path="/x")]),
            "device_not_dict": variant(devices=["a"]),
            "bad_hash": variant(devices=[device("a", [], {}, device_id_sha256="ABC")]),
            "hash_not_str": variant(devices=[device("a", [], {}, evidence_sha256=5)]),
            "bad_os": variant(devices=[device("a", [], {}, os_version="mac os")]),
            "os_not_str": variant(devices=[device("a", [], {}, os_version=15)]),
            "unknown_scenario": variant(devices=[device("a", ["nope"], {})]),
            "bad_outcome": variant(devices=[device("a", [], {"codex": "maybe"})]),
            "unknown_provider": variant(devices=[device("a", [], {"gemini": "passed"})]),
            "scenarios_not_dict": variant(devices=[dict(device("a", [], {}), scenarios=["x"])]),
            "bad_differences": variant(intentional_provider_differences=["unreviewed"]),
            "differences_not_list": variant(intentional_provider_differences="auth"),
            "secret_text": variant(devices=[device("a", [], {}, os_version="token")]),
        }
        for name, evidence in cases.items():
            with self.subTest(case=name):
                self.assertSame("verification.evaluate", identity=identity, evidence=evidence,
                                runner=RUNNERS["signed"])
        passed = self.python.call("verification.evaluate", identity=identity, evidence=complete)
        self.assertEqual((passed["status"], passed["blocker_codes"]), ("passed", []))
        unsigned = dict(identity, developer_id_signed=False, signer_team_id="")
        self.assertSame("verification.evidence_template", identity=unsigned)
        self.assertSame("verification.evaluate", identity=unsigned, evidence=complete)

    def test_source_harness_report(self):
        source = str(REPO)
        rust = self.rust.call("verification.run", source_root=source)
        python = self.python.call("verification.run")
        self.assertEqual(rust, python)
        self.assertEqual(python["status"], "passed")
        self.assertRegex(python["report_sha256"], r"^[0-9a-f]{64}$")
        self.assertSame("verification.run", git_binary=str(self.root / "no-such-git"))


if __name__ == "__main__":
    unittest.main()
