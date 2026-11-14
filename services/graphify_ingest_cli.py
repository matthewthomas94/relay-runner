#!/usr/bin/env python3
"""Ingest registered projects into one Graphify database and print the counts.

A temporary bridge for the Rust artifact migration (RR-495): it rebuilds the
disposable Graphify projection through `graphify_ingest.ingest_registered_projects`
until graph ingest is ported to Rust (RR-499). The ingest only reads project
boards, the run ledger and the registry, so it never takes a project's
artifact writer lock and is safe to run while the migration holds it.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from graphify_core import GraphifyCoreStore
from graphify_ingest import ingest_registered_projects


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graph", required=True, type=Path)
    parser.add_argument("--registry", required=True, type=Path)
    parser.add_argument("--runs-db", type=Path)
    args = parser.parse_args()
    counts = ingest_registered_projects(
        GraphifyCoreStore(args.graph),
        registry_path=args.registry,
        runs_db_path=args.runs_db,
        index_files=True,
    )
    print(json.dumps(counts, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
