"""Show or set a project's Relay work style (auto, direct or orchestrated).

Shared by the /work-style skill for Claude and Codex, voice requests such as
"switch to direct mode", and anyone at a terminal. Writes the same
work-styles.json the Workspace picker uses, so all three stay in step.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from command_actions import WORK_STYLES, project_work_style, set_project_work_style  # noqa: E402

DESCRIPTIONS = {
    "auto": "decides per request, and asks when unsure",
    "direct": "makes changes now, without tickets",
    "orchestrated": "turns changes into tickets for workers",
}


def _project_root(path: str | None) -> Path:
    start = Path(path or ".").expanduser().resolve()
    try:
        top = subprocess.run(["git", "-C", str(start), "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True).stdout.strip()
        return Path(top)
    except (OSError, subprocess.CalledProcessError):
        return start


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="relay-work-style", description=__doc__.splitlines()[0])
    parser.add_argument("action", nargs="?", choices=("show", "set"), default="show")
    parser.add_argument("style", nargs="?", choices=WORK_STYLES)
    parser.add_argument("--repo", help="Project path (default: the git project of the current directory)")
    args = parser.parse_args(argv)
    repo = _project_root(args.repo)
    if args.action == "set":
        if not args.style:
            parser.error("set needs a style: " + ", ".join(WORK_STYLES))
        set_project_work_style(repo, args.style)
    style = project_work_style(repo)
    print(f"{repo.name}: {style} ({DESCRIPTIONS[style]})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
