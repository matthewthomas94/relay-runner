"""The orchestrator daemon's documented route table.

docs/specs/orchestrator-http-api.md lists every route in its "Route index".
Until RR-487 this module also read the routes the Python daemon served from
its source; the Rust daemon is now the only one, and the route probe in
test_orchestrator_contract_routes.py sends every documented route to it.
"""

from __future__ import annotations

import re
from pathlib import Path

API_DOCUMENT = Path(__file__).resolve().parents[2] / "docs" / "specs" / "orchestrator-http-api.md"

PARAMETER = "{}"

_ROW_RE = re.compile(r"^\|\s*(GET|POST)\s*\|\s*`([^`]+)`\s*\|")


def documented_routes(text: str = None) -> dict:
    """The route index of the API document: (method, path) -> the documented template."""
    text = API_DOCUMENT.read_text(encoding="utf-8") if text is None else text
    routes = {}
    for line in text.splitlines():
        match = _ROW_RE.match(line)
        if match:
            method, template = match.groups()
            key = (method, normalise(template))
            if key in routes:
                raise AssertionError("route listed twice: %s %s" % (method, template))
            routes[key] = template
    return routes


def normalise(template: str) -> str:
    return re.sub(r"\{[^}/]*\}", PARAMETER, template.split("?", 1)[0])
