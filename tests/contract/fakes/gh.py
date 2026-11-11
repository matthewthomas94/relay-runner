#!/usr/bin/env python3
"""Stand-in for the GitHub CLI.

The contract suite puts a wrapper named `gh` on the daemon's PATH. The fake
never reaches the network: it records the call and answers as a machine with
no GitHub sign-in would, unless a plan in
`$RELAY_CONTRACT_FAKE_STATE/plans/gh.json` says otherwise.

Plan keys: `exit_code` (default 1), `stdout`, `stderr`.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

STATE = Path(os.environ.get("RELAY_CONTRACT_FAKE_STATE", ""))


def main() -> int:
    plan = {}
    if str(STATE):
        STATE.mkdir(parents=True, exist_ok=True)
        with (STATE / "invocations.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({
                "event": "launch", "provider": "gh", "role": "gh", "argv": sys.argv[1:],
                "cwd": os.getcwd(), "pid": os.getpid(),
            }, sort_keys=True) + "\n")
        try:
            plan = json.loads((STATE / "plans" / "gh.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            plan = {}
    sys.stdout.write(plan.get("stdout", ""))
    sys.stderr.write(plan.get("stderr", "You are not logged into any GitHub hosts.\n"))
    return int(plan.get("exit_code", 1))


if __name__ == "__main__":
    sys.exit(main())
