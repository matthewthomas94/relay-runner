import os
import plistlib
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


class GenerateAppcastScriptTests(unittest.TestCase):
    def test_generate_appcast_default_feed_matches_bundle_feed(self):
        info = plistlib.loads((PROJECT_ROOT / "Info.plist").read_bytes())
        script = (PROJECT_ROOT / "scripts/generate-appcast.sh").read_text()

        self.assertIn(info["SUFeedURL"], script)
        self.assertNotIn(
            "github.com/matthewthomas94/relay-runner/releases/latest/download/appcast.xml",
            script,
        )

    def test_generate_appcast_preserves_all_versions(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            dist = tmp_path / "dist"
            dist.mkdir()
            archive = dist / "RelayRunner.zip"
            archive.write_bytes(b"fake archive")

            sparkle_bin = tmp_path / "sparkle-bin"
            sparkle_bin.mkdir()
            args_log = tmp_path / "generate_appcast.args"
            fake_generate_appcast = sparkle_bin / "generate_appcast"
            fake_generate_appcast.write_text(
                textwrap.dedent(
                    f"""\
                    #!/bin/sh
                    printf '%s\\n' "$@" > "{args_log}"
                    output=""
                    previous=""
                    for arg in "$@"; do
                        if [ "$previous" = "-o" ]; then
                            output="$arg"
                            break
                        fi
                        previous="$arg"
                    done
                    if [ -z "$output" ]; then
                        echo "missing -o output" >&2
                        exit 1
                    fi
                    cat > "$output" <<'XML'
                    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
                      <channel>
                        <item>
                          <title>Relay Runner</title>
                          <enclosure url="RelayRunner.zip" sparkle:edSignature="signed"/>
                        </item>
                      </channel>
                    </rss>
                    XML
                    """
                )
            )
            fake_generate_appcast.chmod(
                fake_generate_appcast.stat().st_mode | stat.S_IXUSR
            )

            env = os.environ.copy()
            env.update(
                {
                    "DIST_DIR": str(dist),
                    "SPARKLE_ARCHIVE_PATH": str(archive),
                    "SPARKLE_APPCAST_OUTPUT": str(dist / "appcast.xml"),
                    "SPARKLE_BIN_DIR": str(sparkle_bin),
                    "SPARKLE_ED_PRIVATE_KEY": "test-private-key",
                    "SPARKLE_APPCAST_URL": "https://127.0.0.1/does-not-exist.xml",
                }
            )

            result = subprocess.run(
                ["bash", "scripts/generate-appcast.sh"],
                cwd=PROJECT_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            args = args_log.read_text().splitlines()
            self.assertIn("--maximum-versions", args)
            self.assertEqual(args[args.index("--maximum-versions") + 1], "0")

    def test_generate_appcast_rejects_invalid_maximum_versions(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "RelayRunner.zip"
            archive.write_bytes(b"fake archive")

            env = os.environ.copy()
            env.update(
                {
                    "SPARKLE_ARCHIVE_PATH": str(archive),
                    "SPARKLE_ED_PRIVATE_KEY": "test-private-key",
                    "SPARKLE_MAXIMUM_VERSIONS": "latest",
                }
            )

            result = subprocess.run(
                ["bash", "scripts/generate-appcast.sh"],
                cwd=PROJECT_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SPARKLE_MAXIMUM_VERSIONS", result.stderr)


if __name__ == "__main__":
    unittest.main()
