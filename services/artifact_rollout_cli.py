#!/usr/bin/env python3
"""Operator CLI for the RR-289 staged artifact rollout policy."""

from __future__ import annotations

import argparse
import dataclasses
import json
from pathlib import Path

from artifact_rollout import (
    COHORTS,
    ArtifactRolloutError,
    ArtifactRolloutStore,
    RolloutEvidence,
)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="Inspect or explicitly change artifact rollout gates.")
    value.add_argument(
        "--state-root",
        type=Path,
        default=Path.home() / "Library/Application Support/relay-runner",
    )
    subcommands = value.add_subparsers(dest="action", required=True)
    subcommands.add_parser("status")

    decision = subcommands.add_parser("decision")
    decision.add_argument("--project-id", required=True)
    decision.add_argument("--project-kind", required=True, choices=("existing", "new", "legacy"))

    for action in ("opt-in", "opt-out"):
        project = subcommands.add_parser(action)
        project.add_argument("--project-id", required=True)
        project.add_argument("--confirm", action="store_true")
        if action == "opt-out":
            project.add_argument("--writers-drained", action="store_true")
            project.add_argument("--sync-frozen", action="store_true")

    evidence = subcommands.add_parser("record-evidence")
    evidence.add_argument("--file", required=True, type=Path)

    promote = subcommands.add_parser("promote")
    promote.add_argument("--cohort", required=True, choices=COHORTS)
    promote.add_argument("--confirm", action="store_true")

    pause = subcommands.add_parser("pause")
    pause.add_argument("--cohort", required=True, choices=COHORTS)
    pause.add_argument("--reason-code", required=True)
    pause.add_argument("--writers-drained", action="store_true")
    pause.add_argument("--sync-frozen", action="store_true")

    resume = subcommands.add_parser("resume")
    resume.add_argument("--cohort", required=True, choices=COHORTS)
    resume.add_argument("--confirm", action="store_true")
    return value


def main() -> int:
    args = parser().parse_args()
    store = ArtifactRolloutStore(args.state_root)
    try:
        if args.action == "status":
            result = store.diagnostics()
        elif args.action == "decision":
            result = dataclasses.asdict(
                store.decision(args.project_id, project_kind=args.project_kind)
            )
        elif args.action in {"opt-in", "opt-out"}:
            enabled = args.action == "opt-in"
            result = dataclasses.asdict(store.set_project_opt_in(
                args.project_id,
                enabled=enabled,
                confirmed=args.confirm,
                writers_drained=getattr(args, "writers_drained", False),
                sync_frozen=getattr(args, "sync_frozen", False),
            ))
        elif args.action == "record-evidence":
            raw = json.loads(args.file.expanduser().read_text(encoding="utf-8"))
            evidence_fields = {
                "evidence_id", "kind", "outcome", "recorded_at", "report_sha256",
                "build_version", "build_number", "bundle_sha256", "signer_team_id",
                "providers", "scenario_ids", "rejection_code",
            }
            if not isinstance(raw, dict) or set(raw) != evidence_fields:
                raise ArtifactRolloutError(
                    "Evidence file must contain exactly the bounded rollout evidence fields.",
                    code="invalid_rollout_evidence",
                    recovery="Use one bounded RolloutEvidence JSON object.",
                )
            result = store.record_evidence(RolloutEvidence(
                evidence_id=raw.get("evidence_id"),
                kind=raw.get("kind"),
                outcome=raw.get("outcome"),
                recorded_at=raw.get("recorded_at"),
                report_sha256=raw.get("report_sha256"),
                build_version=raw.get("build_version"),
                build_number=raw.get("build_number"),
                bundle_sha256=raw.get("bundle_sha256"),
                signer_team_id=raw.get("signer_team_id"),
                providers=tuple(raw.get("providers") or ()),
                scenario_ids=tuple(raw.get("scenario_ids") or ()),
                rejection_code=raw.get("rejection_code"),
            ))
        elif args.action == "promote":
            result = store.promote_cohort(args.cohort, confirmed=args.confirm)
        elif args.action == "pause":
            result = store.pause_cohort(
                args.cohort,
                writers_drained=args.writers_drained,
                sync_frozen=args.sync_frozen,
                reason_code=args.reason_code,
            )
        else:
            result = store.resume_cohort(args.cohort, confirmed=args.confirm)
        print(json.dumps({"ok": True, "result": result}, sort_keys=True, indent=2))
        return 0
    except (ArtifactRolloutError, OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        print(json.dumps({
            "ok": False,
            "error_code": getattr(error, "code", "invalid_rollout_input"),
            "error": str(error),
            "recovery": getattr(
                error,
                "recovery",
                "Review the bounded input file and retry without changing cohort state.",
            ),
        }, sort_keys=True, indent=2))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
