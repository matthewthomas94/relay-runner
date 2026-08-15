import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class MCPLifecycleProbeTests(unittest.TestCase):
    def test_built_adapters_expose_only_legacy_lifecycle(self):
        bin_dir = subprocess.check_output(
            ["swift", "build", "--show-bin-path"], cwd=ROOT, text=True
        ).strip()
        result = subprocess.run(
            [
                sys.executable,
                "scripts/mcp-lifecycle-probe.py",
                "--bin-dir",
                bin_dir,
                "--skip-client-probes",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        report = json.loads(result.stdout)
        self.assertEqual(set(report["adapters"]), {
            "relay-actions-mcp", "relay-vision-mcp", "relay-orchestrator-mcp",
        })
        for adapter in report["adapters"].values():
            self.assertEqual(adapter["stateless_discover"], "-32601 method not found")
            self.assertIn("no explicit application-handle", adapter["request_handle"])


if __name__ == "__main__":
    unittest.main()
