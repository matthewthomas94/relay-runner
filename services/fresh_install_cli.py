#!/usr/bin/env python3
"""CLI adapter for supported Relay Runner reinstall/reset recovery."""

from __future__ import annotations

import argparse
import dataclasses
import json
from pathlib import Path

from fresh_install import FreshInstallCoordinator, FreshInstallError


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="Preserving reinstall and recoverable Relay state reset")
    actions = value.add_mutually_exclusive_group()
    actions.add_argument("--reset-state", action="store_true")
    actions.add_argument("--restore-reset", type=Path)
    value.add_argument("--app", type=Path, help="Reviewed Relay Runner.app source for normal reinstall")
    value.add_argument("--destination", type=Path, default=Path("/Applications/Relay Runner.app"))
    value.add_argument(
        "--state-root",
        type=Path,
        default=Path.home() / "Library/Application Support/relay-runner",
    )
    value.add_argument("--trash-root", type=Path)
    value.add_argument("--execute", action="store_true")
    value.add_argument("--confirm-daemon-stopped", action="store_true")
    return value


def main() -> int:
    args = parser().parse_args()
    try:
        if args.restore_reset:
            result = FreshInstallCoordinator.restore_reset(
                args.restore_reset,
                execute=args.execute,
                confirm_daemon_stopped=args.confirm_daemon_stopped,
            )
        else:
            coordinator = FreshInstallCoordinator(
                state_root=args.state_root,
                trash_root=args.trash_root,
            )
            if args.reset_state:
                result = (
                    coordinator.reset_state(
                        execute=True,
                        confirm_daemon_stopped=args.confirm_daemon_stopped,
                    )
                    if args.execute
                    else coordinator.preview_reset()
                )
            else:
                if args.app is None:
                    raise FreshInstallError(
                        "Normal reinstall requires --app <reviewed Relay Runner.app>.",
                        recovery="Build/select the app bundle, run preflight, then add --execute.",
                    )
                result = (
                    coordinator.reinstall(
                        source_app=args.app,
                        destination_app=args.destination,
                        execute=True,
                    )
                    if args.execute
                    else coordinator.preview_reinstall(
                        source_app=args.app,
                        destination_app=args.destination,
                    )
                )
        print(json.dumps({"ok": True, "result": dataclasses.asdict(result)}, sort_keys=True, indent=2))
        return 0
    except FreshInstallError as error:
        print(json.dumps({"ok": False, "error": str(error), "recovery": error.recovery}, indent=2))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
