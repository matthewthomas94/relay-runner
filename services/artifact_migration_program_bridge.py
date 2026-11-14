#!/usr/bin/env python3
"""Run the migration's Program export and Graphify rebuild for the Rust port.

A temporary bridge for ``relay_artifacts::migration`` (RR-495): the Program
capture export and the clean Graphify rebuild live in ``program_artifacts`` and
``graphify_*``, which RR-499 ports. Until then the Rust migration runs this
script for its ``materialized`` stage. It calls this module's own
``ArtifactMigrationCoordinator._migrate_program_and_rebuild`` on the recorded
journal, so the export, the rebuilt database and the journal it writes are the
Python daemon's exactly.

The Rust process holds the project's artifact writer lock for the whole
migration and waits for this one, so the bridge re-enters that lock as a
nested writer instead of taking it. Prints one JSON object: ``{"ok": true}``,
or the error class, message, recovery and report.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    from services import artifact_store
    from services.artifact_migration import ArtifactMigrationCoordinator, ArtifactMigrationError
except ModuleNotFoundError:  # Installed direct-script layout.
    import artifact_store  # type: ignore[no-redef]
    from artifact_migration import ArtifactMigrationCoordinator, ArtifactMigrationError  # type: ignore[no-redef]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--state-root", required=True, type=Path)
    parser.add_argument("--registry", required=True, type=Path)
    parser.add_argument("--runs-db", type=Path)
    parser.add_argument("--graphify", required=True, type=Path)
    parser.add_argument("--device-id", default="migration-device")
    parser.add_argument("--provider")
    args = parser.parse_args()
    coordinator = ArtifactMigrationCoordinator(
        args.repo,
        args.project_id,
        args.state_root,
        registry_path=args.registry,
        runs_db_path=args.runs_db,
        graphify_path=args.graphify,
        device_id=args.device_id,
        provider=args.provider,
    )
    # The calling Rust migration holds this lock on our behalf.
    artifact_store._global_lock_depth.depths = {str(coordinator.store.lock_path): 1}
    try:
        journal = coordinator._load_journal()
        if journal.get("stage") != "materialized":
            raise ArtifactMigrationError(
                f"Program bridge expected the materialized stage, found {journal.get('stage')!r}.",
                recovery="Resume the migration with the same journal.",
            )
        coordinator._migrate_program_and_rebuild(journal)
    except ArtifactMigrationError as error:
        answer = {
            "ok": False, "error": type(error).__name__, "message": str(error),
            "recovery": error.recovery, "report": error.report,
        }
    except Exception as error:  # noqa: BLE001 - reported to the Rust caller by class
        answer = {"ok": False, "error": type(error).__name__, "message": str(error)}
    else:
        answer = {"ok": True}
    print(json.dumps(answer, sort_keys=True, default=str))
    return 0 if answer["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
