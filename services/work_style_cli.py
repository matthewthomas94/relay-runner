"""Show or set the session's Relay work style (auto, direct or orchestrated).

Shared by the /work-style skill for Claude and Codex, voice requests such as
"switch to direct mode", and anyone at a terminal. `set` writes the same
session-work-style.json the Start button's menu uses, so all three stay in
step; the choice covers every project and wins over a project's
`.relay-runner.toml`. `show` prints the effective style for a project and
where it comes from.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from command_actions import WORK_STYLES, set_session_work_style, work_style_and_source  # noqa: E402

DESCRIPTIONS = {
    "auto": "decides per request, and asks when unsure",
    "direct": "makes changes now, without tickets",
    "orchestrated": "turns changes into tickets for workers",
}
SOURCES = {
    "env": "RELAY_WORK_STYLE",
    "session": "the session's choice",
    "project": "the project's .relay-runner.toml",
    "default": "the default",
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
    parser.add_argument("--repo", help="Project to report on (default: the git project of the current directory)")
    args = parser.parse_args(argv)
    repo = _project_root(args.repo)
    if args.action == "set":
        if not args.style:
            parser.error("set needs a style: " + ", ".join(WORK_STYLES))
        set_session_work_style(args.style)
    style, source = work_style_and_source(repo)
    print(f"{repo.name}: {style} ({DESCRIPTIONS[style]}), from {SOURCES[source]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
