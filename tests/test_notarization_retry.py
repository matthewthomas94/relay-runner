import shlex
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class NotarizationRetryTests(unittest.TestCase):
    def run_stapler(self, statuses, action="validate"):
        script = (ROOT / "scripts/build-dmg.sh").read_text()
        function = "stapler_with_retry() {" + script.split(
            "stapler_with_retry() {", 1
        )[1].split("\n}", 1)[0] + "\n}"
        harness = """
set -euo pipefail
calls=0
xcrun() {
    calls=$((calls + 1))
    printf 'call:%s:%s:%s\n' "$1" "$2" "$3"
    return "${statuses[$((calls - 1))]}"
}
sleep() { printf 'sleep:%s\n' "$1"; }
"""
        harness += "statuses=(" + " ".join(map(str, statuses)) + ")\n"
        harness += function + "\n"
        harness += shlex.join(["stapler_with_retry", action, "/tmp/Relay Runner.app"])
        harness += "\nprintf 'completed\\n'\n"
        return subprocess.run(["bash", "-c", harness], capture_output=True, text=True)

    def test_success_does_not_retry_and_preserves_path_with_spaces(self):
        result = self.run_stapler([0])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "call:stapler:validate:/tmp/Relay Runner.app", "completed"
        ])

    def test_transient_ticket_service_failure_recovers_for_both_actions(self):
        for action in ["staple", "validate"]:
            with self.subTest(action=action):
                result = self.run_stapler([68, 68, 0], action)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.count("call:"), 3)
                self.assertIn("sleep:5\n", result.stdout)
                self.assertIn("sleep:10\n", result.stdout)
                self.assertTrue(result.stdout.endswith("completed\n"))

    def test_persistent_service_failure_stops_packaging_after_five_attempts(self):
        result = self.run_stapler([68] * 5)
        self.assertEqual(result.returncode, 68)
        self.assertEqual(result.stdout.count("call:"), 5)
        self.assertEqual(result.stdout.count("sleep:"), 4)
        self.assertNotIn("completed", result.stdout)

    def test_invalid_or_revoked_ticket_is_not_retried(self):
        for status in [65, 66, 77]:
            with self.subTest(status=status):
                result = self.run_stapler([status])
                self.assertEqual(result.returncode, status)
                self.assertEqual(result.stdout.count("call:"), 1)
                self.assertNotIn("sleep:", result.stdout)
                self.assertNotIn("completed", result.stdout)

    def test_permanent_failure_after_service_retry_still_stops_packaging(self):
        result = self.run_stapler([68, 77])
        self.assertEqual(result.returncode, 77)
        self.assertEqual(result.stdout.count("call:"), 2)
        self.assertEqual(result.stdout.count("sleep:"), 1)
        self.assertNotIn("completed", result.stdout)


if __name__ == "__main__":
    unittest.main()
