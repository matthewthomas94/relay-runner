#!/usr/bin/env python3
"""Capture the databases a released orchestrator daemon leaves behind.

Usage, from the repository root:

    /opt/homebrew/bin/python3 tests/contract/fixtures/orchestrator/make_release_fixture.py v0.5.4

The release's `services/` is extracted from its git tag into a temporary
directory and run as a process in the contract sandbox. Releases before
RR-485 have no isolation switches, so the extracted copy's fixed `/tmp` paths
are rewritten to the sandbox runtime directory first; nothing else changes.
The daemon then runs a short scripted session (a merged run, a failed run, a
queue drain, an orchestrator session and a recorded command), stops, and
every database is written as a SQL dump to `<release>/<name>.sql`, with the
sandbox root replaced by `<ROOT>` and `PRAGMA user_version` kept.

This is a maintenance tool, not part of the suite. It imports nothing from
`services/`.
"""

from __future__ import annotations

import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[3]
DATABASES = (
    "runs.db", "queue_drains.db", "orchestrator_sessions.db", "orchestrator_commands.db",
    "messenger_outcomes.db", "followup_proposals.db", "continuity_reports.db", "graphify.db",
)


def extract(release: str, target: Path) -> Path:
    archive = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "archive", release, "services"],
        check=True, capture_output=True,
    ).stdout
    subprocess.run(["tar", "-x", "-C", str(target)], input=archive, check=True)
    daemon = target / "services" / "orchestrator.py"
    source = daemon.read_text(encoding="utf-8")
    if "RELAY_ORCHESTRATOR_RUNTIME_DIR" not in source:
        source = re.sub(
            r'Path\(f?"/tmp/([^"]*)"\)',
            lambda match: 'Path(os.environ["RELAY_ORCHESTRATOR_RUNTIME_DIR"]) / f"%s"' % match.group(1),
            source,
        )
        source = source.replace(
            '"/tmp/voice_bridge.sock"', 'os.environ["RELAY_ORCHESTRATOR_RUNTIME_DIR"] + "/voice_bridge.sock"',
        )
        if '"/tmp' in source:
            raise SystemExit("unpatched /tmp path left in the extracted daemon")
        daemon.write_text(source, encoding="utf-8")
    return daemon


def dump(database: Path, root: Path) -> str:
    connection = sqlite3.connect(str(database))
    try:
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        lines = ["PRAGMA user_version=%d;" % version, *connection.iterdump()]
    finally:
        connection.close()
    return "\n".join(lines).replace(str(root), "<ROOT>") + "\n"


def main() -> int:
    release = sys.argv[1]
    with tempfile.TemporaryDirectory(prefix="relay-release-") as temporary:
        daemon = extract(release, Path(temporary))
        os.environ["RELAY_ORCHESTRATOR_CMD"] = "%s %s" % (sys.executable, daemon)
        sys.path.insert(0, str(HERE.parents[1]))
        from orchestrator_contract_support import Sandbox  # noqa: E402

        cleanups = []
        box = Sandbox(lambda function, *arguments: cleanups.append((function, arguments)))
        try:
            repo = box.make_repo("released")
            box.write_ticket(repo, "CT-1")
            box.write_ticket(repo, "CT-2")
            box.write_ticket(repo, "CT-3", status="ready")
            box.write_ticket(repo, "CT-4", status="ready", depends_on=["CT-3"])
            box.plan("implementation", "CT-2", exit_code=3)
            box.plan("implementation", "CT-3", hold=str(box.hold("released")))
            box.start()
            for ticket_id, state in (("CT-1", "Merged"), ("CT-2", "Failed")):
                run = box.post("/v1/runs", {"ticket_id": ticket_id, "repo_path": str(repo)}).json["run"]
                box.wait_for_run(run["id"], state)
            box.post("/v1/ready-sweep", {"repo_path": str(repo), "trigger": "release-fixture"})
            session = box.post("/v1/orchestrator-session/ensure", {
                "repo_path": str(repo), "provider": "claude", "source": "release-fixture",
            }).json["orchestrator_session"]
            box.post("/v1/orchestrator-session/command", {
                "repo_path": str(repo), "source_text": "Run the release fixture.",
                "relay_command_seq": 1, "relay_command_id": "release-fixture-1",
                "session_id": session["id"], "provider": "claude",
            })
            box.release(box.hold("released"))
            box.wait_for(
                lambda: all(run["state"] == "Merged" for run in box.get("/v1/runs").json["runs"]
                            if run["ticket_id"] in {"CT-3", "CT-4"})
                and len(box.get("/v1/runs").json["runs"]) == 4,
                message="queued runs merged",
            )
            box.stop()
            data = box.home / "Library" / "Application Support" / "relay-runner" / "orchestrator"
            output = HERE / release
            output.mkdir(exist_ok=True)
            for name in DATABASES:
                (output / (Path(name).stem + ".sql")).write_text(dump(data / name, box.root))
        finally:
            for function, arguments in reversed(cleanups):
                function(*arguments)
    print("wrote", HERE / release)
    return 0


if __name__ == "__main__":
    sys.exit(main())
