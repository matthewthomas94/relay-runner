#!/usr/bin/env python3
"""CLI adapter for the journaled artifact migration coordinator."""

from __future__ import annotations

import argparse
import dataclasses
import json
from pathlib import Path

from artifact_migration import ArtifactMigrationCoordinator, ArtifactMigrationError


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(
        description="Guarded RR-270 phase-8 migration; preview is read-only and execution is journaled."
    )
    value.add_argument("action", choices=("preview", "migrate", "rollback"))
    value.add_argument("--repo", required=True, type=Path)
    value.add_argument("--project-id", required=True)
    value.add_argument(
        "--state-root",
        type=Path,
        default=Path.home() / "Library/Application Support/relay-runner",
    )
    value.add_argument("--registry", type=Path)
    value.add_argument("--runs-db", type=Path)
    value.add_argument("--graphify-db", type=Path)
    value.add_argument(
        "--confirm-source-cleanup",
        action="store_true",
        help="Required for migrate after reviewing the preflight manifest.",
    )
    value.add_argument(
        "--confirm-first-push",
        action="store_true",
        help="Explicitly allow the first normal artifact-ref push; never enables force push.",
    )
    value.add_argument("--provider", choices=("codex", "claude"))
    return value


def main() -> int:
    args = parser().parse_args()
    state = args.state_root.expanduser().resolve()
    coordinator = ArtifactMigrationCoordinator(
        args.repo,
        args.project_id,
        state,
        registry_path=args.registry or state / "projects/registry-v2.json",
        runs_db_path=args.runs_db or state / "orchestrator/runs.db",
        graphify_path=args.graphify_db or state / "orchestrator/graphify.db",
        device_id="migration-cli",
        provider=args.provider,
    )
    try:
        if args.action == "preview":
            result = coordinator.preview().as_dict()
        elif args.action == "migrate":
            result = dataclasses.asdict(
                coordinator.migrate(
                    confirm_source_cleanup=args.confirm_source_cleanup,
                    confirm_first_push=args.confirm_first_push,
                )
            )
        else:
            result = dataclasses.asdict(coordinator.rollback())
    except ArtifactMigrationError as error:
        print(json.dumps({
            "ok": False,
            "error": str(error),
            "recovery": error.recovery,
            "report": error.report,
        }, sort_keys=True, indent=2))
        return 2
    print(json.dumps({"ok": True, "result": result}, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
