#!/usr/bin/env python3
"""CLI for RR-289 source and signed-installed artifact verification."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path
from typing import Any, Mapping

from artifact_verification import (
    ArtifactVerificationError,
    RR289SourceVerificationHarness,
    SignedInstalledAppGate,
)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(
        description="Run RR-289 disposable source checks or evaluate signed installed evidence."
    )
    subcommands = value.add_subparsers(dest="action", required=True)

    source = subcommands.add_parser("source-harness")
    source.add_argument("--output", type=Path)

    inspect = subcommands.add_parser("inspect-installed")
    inspect.add_argument("--app", type=Path, default=Path("/Applications/Relay Runner.app"))
    inspect.add_argument("--output", type=Path)

    template = subcommands.add_parser("installed-template")
    template.add_argument("--app", type=Path, default=Path("/Applications/Relay Runner.app"))
    template.add_argument("--output", required=True, type=Path)

    evaluate = subcommands.add_parser("evaluate-installed")
    evaluate.add_argument("--app", type=Path, default=Path("/Applications/Relay Runner.app"))
    evaluate.add_argument("--evidence", required=True, type=Path)
    evaluate.add_argument("--output", type=Path)
    return value


def main() -> int:
    args = parser().parse_args()
    try:
        if args.action == "source-harness":
            result = RR289SourceVerificationHarness().run()
        else:
            gate = SignedInstalledAppGate()
            identity = gate.inspect(args.app)
            if args.action == "inspect-installed":
                result = {"status": "passed", "bundle": identity.as_dict()}
            elif args.action == "installed-template":
                result = gate.evidence_template(identity)
            else:
                result = gate.evaluate(identity, _read_json(args.evidence))
        output = getattr(args, "output", None)
        # The installed template is itself the file consumed by
        # evaluate-installed. Other actions use the ordinary CLI envelope.
        _emit(result if args.action == "installed-template" else {"ok": True, "result": result}, output)
        return 0
    except ArtifactVerificationError as error:
        _emit(
            {
                "ok": False,
                "error_code": error.code,
                "error": str(error),
                "recovery": error.recovery,
            },
            getattr(args, "output", None),
        )
        return 2
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        _emit(
            {
                "ok": False,
                "error_code": "invalid_evidence_file",
                "error": "Installed evidence file is missing or invalid JSON.",
                "recovery": "Regenerate the bounded template and record reviewed scenario outcomes.",
            },
            getattr(args, "output", None),
        )
        return 2


def _read_json(path: Path) -> Mapping[str, Any]:
    value = json.loads(path.expanduser().read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ArtifactVerificationError(
            "Installed evidence root must be an object.",
            code="invalid_installed_evidence",
            recovery="Regenerate the bounded schema-1 evidence template.",
        )
    return value


def _emit(value: Mapping[str, Any], output: Path | None) -> None:
    payload = json.dumps(value, sort_keys=True, indent=2) + "\n"
    if output is None:
        print(payload, end="")
        return
    destination = output.expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()


if __name__ == "__main__":
    raise SystemExit(main())
