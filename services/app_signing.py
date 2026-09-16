"""Keep Relay Runner's macOS permission identity stable across replacements."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


SIGNING_TEAM = "QK9K4AQRNH"
# Apple's default Developer ID requirement, independent of version, cdhash,
# and certificate renewal. TCC stores this requirement when access is granted.
RELEASE_REQUIREMENT = (
    'identifier "com.relayrunner.app" and anchor apple generic '
    'and certificate 1[field.1.2.840.113635.100.6.2.6] '
    'and certificate leaf[field.1.2.840.113635.100.6.1.13] '
    f'and certificate leaf[subject.OU] = "{SIGNING_TEAM}"'
)


class AppSigningError(RuntimeError):
    pass


def resolve_signing_identity(explicit: str = "", *, allow_adhoc: bool = False) -> str:
    if explicit and explicit != "-":
        return explicit
    if explicit != "-":
        result = subprocess.run(
            ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            match = re.search(
                rf'\b([0-9A-Fa-f]{{40}}) "Developer ID Application: [^"\n]+ \({SIGNING_TEAM}\)"',
                result.stdout,
            )
            if match:
                return match.group(1)
    if allow_adhoc:
        return ""
    raise AppSigningError(
        f"No Developer ID signing identity for Relay Runner team {SIGNING_TEAM}. "
        "Unlock/import that certificate or set SIGN_IDENTITY. "
        "For an isolated test artifact only, set RELAY_ALLOW_ADHOC_SIGNING=1; "
        "ad-hoc rebuilds cannot preserve macOS permissions."
    )


def verify_update_identity(source: Path, installed: Path | None = None) -> None:
    result = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict",
         "--test-requirement", "=" + RELEASE_REQUIREMENT, str(source)],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise AppSigningError(
            "App does not have Relay Runner's valid Developer ID signature; "
            "replacing the installed app would risk losing macOS permissions. "
            + result.stderr.strip()
        )
    if installed is None or not installed.exists():
        return
    previous = subprocess.run(
        ["/usr/bin/codesign", "--display", "--requirements", "-", "--verbose=2", str(installed)],
        capture_output=True, text=True,
    )
    details = previous.stdout + "\n" + previous.stderr
    if previous.returncode:
        raise AppSigningError("Cannot read the installed app's signing identity; keeping it in place.")
    if "Signature=adhoc" in details:
        # Moving from an old ad-hoc build to Developer ID is a one-time repair.
        # Its hash-based grants cannot transfer, but subsequent builds are stable.
        print("Previous app was ad-hoc signed; macOS may require one final permission grant.", file=sys.stderr)
        return
    requirement = next(
        (line.removeprefix("designated => ") for line in details.splitlines()
         if line.startswith("designated => ")),
        "",
    )
    if not requirement:
        raise AppSigningError("Installed app has no designated requirement; keeping it in place.")
    compatible = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", "--test-requirement", "=" + requirement, str(source)],
        capture_output=True, text=True,
    )
    if compatible.returncode:
        raise AppSigningError("Update changes the installed app's permission identity; keeping it in place.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("identity")
    verify = commands.add_parser("verify")
    verify.add_argument("app", type=Path)
    verify.add_argument("--installed", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "identity":
            print(resolve_signing_identity(
                os.environ.get("SIGN_IDENTITY", ""),
                allow_adhoc=os.environ.get("RELAY_ALLOW_ADHOC_SIGNING") == "1",
            ))
        else:
            verify_update_identity(args.app, args.installed)
    except AppSigningError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
