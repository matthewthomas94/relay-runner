#!/usr/bin/env python3
"""Generate the Lucide icon data drawn by LucideImage.

Downloads icons/<name>.svg for every name in ICONS from the official Lucide
repository at LUCIDE_TAG, parses each file's child elements and writes
Sources/relay-runner/Board/LucideIcons.generated.swift. The renderer that turns
that data into SwiftUI images is Sources/relay-runner/Board/LucideIcon.swift.

Usage:
    /opt/homebrew/bin/python3 -I scripts/generate-lucide-icons.py [--cache DIR]

With --cache, each SVG is read from DIR/<tag>/<name>.svg when that file exists
and is saved there after a download, so a re-run needs no network. Without it,
every SVG is downloaded. An unknown element or attribute, a missing icon, or a
root <svg> that differs from Lucide's standard header stops the script before
anything is written.

To move to a newer Lucide release, change LUCIDE_TAG and LUCIDE_COMMIT, re-run,
and review the diff of the generated file. Lucide is ISC licensed; see
THIRD_PARTY_NOTICES.md.
"""

from __future__ import annotations

import argparse
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

LUCIDE_TAG = "1.70.0"
# The commit LUCIDE_TAG pointed at when it was pinned, recorded for audit.
LUCIDE_COMMIT = "b826f0c527e1498f5e46f41ca0277ccab144bf31"
RAW_URL = "https://raw.githubusercontent.com/lucide-icons/lucide/{tag}/icons/{name}.svg"

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Sources/relay-runner/Board/LucideIcons.generated.swift"

# Lucide icon names at LUCIDE_TAG, alphabetical. Each becomes a camelCase
# LucideIcon case. Lucide 1.x dropped these older names; their replacements come
# from the replacement icon's own metadata aliases (icons/<name>.json):
#   circle-alert -> circle-exclamation-point, circle-help -> circle-question-mark,
#   history -> rotate-ccw-clock, trash-2 -> trash,
#   triangle-alert -> triangle-exclamation-point.
ICONS = [
    "app-window",
    "arrow-down",
    "arrow-down-to-line",
    "arrow-right",
    "arrow-up-right",
    "audio-waveform",
    "badge-check",
    "bell",
    "check",
    "chevron-down",
    "chevron-right",
    "circle",
    "circle-check",
    "circle-exclamation-point",
    "circle-minus",
    "circle-question-mark",
    "circle-user",
    "circle-x",
    "clock",
    "columns-3",
    "copy",
    "download",
    "ellipsis",
    "external-link",
    "eye",
    "fast-forward",
    "file-text",
    "folder",
    "folder-open",
    "folder-plus",
    "forward",
    "git-branch",
    "grip-vertical",
    "hand",
    "hourglass",
    "house",
    "image",
    "image-plus",
    "info",
    "kanban",
    "key-round",
    "keyboard",
    "laptop",
    "layers",
    "link",
    "list",
    "locate",
    "lock",
    "lock-open",
    "log-out",
    "map-pin",
    "mic",
    "mic-off",
    "minus",
    "monitor",
    "moon",
    "notebook-text",
    "octagon-x",
    "panel-top",
    "paperclip",
    "pause",
    "pencil",
    "play",
    "plus",
    "pointer",
    "power",
    "qr-code",
    "refresh-cw",
    "rotate-ccw",
    "rotate-ccw-clock",
    "rotate-cw",
    "save",
    "search",
    "settings",
    "shield",
    "shield-check",
    "smartphone",
    "sparkles",
    "square",
    "square-arrow-out-up-right",
    "square-dashed",
    "square-terminal",
    "sticky-note",
    "terminal",
    "trash",
    "triangle-exclamation-point",
    "undo-2",
    "video",
    "volume-2",
    "wifi",
    "x",
    "zap",
]

SVG_NS = "{http://www.w3.org/2000/svg}"

# Lucide's standard root header. Any other root attribute, or a different
# value, means the source format changed and the renderer needs a look.
ROOT_ATTRIBUTES = {
    "width": "24",
    "height": "24",
    "viewBox": "0 0 24 24",
    "fill": "none",
    "stroke": "currentColor",
    "stroke-width": "2",
    "stroke-linecap": "round",
    "stroke-linejoin": "round",
}

# Supported child elements: required attributes, then optional attributes with
# their SVG defaults (None means "absent", resolved by the renderer).
ELEMENTS: dict[str, tuple[list[str], dict[str, str | None]]] = {
    "path": (["d"], {}),
    "circle": (["r"], {"cx": "0", "cy": "0"}),
    "ellipse": (["rx", "ry"], {"cx": "0", "cy": "0"}),
    "rect": (["width", "height"], {"x": "0", "y": "0", "rx": None, "ry": None}),
    "line": ([], {"x1": "0", "y1": "0", "x2": "0", "y2": "0"}),
    "polyline": (["points"], {}),
    "polygon": (["points"], {}),
}

# Per-element fill. Lucide fills a few small dots with currentColor; they are
# still stroked, because stroke is inherited from the root.
FILL_VALUES = {"none", "currentColor"}

NAME = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
NUMBER = re.compile(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
SEPARATORS = re.compile(r"[\s,]*")
PATH_DATA = re.compile(r"\s*[Mm][MmLlHhVvCcSsQqTtAaZz0-9eE.,+\-\s]*")

# Swift keywords a case name could collide with; those are backtick-escaped.
SWIFT_KEYWORDS = {
    "as", "break", "case", "catch", "class", "continue", "default", "defer",
    "do", "else", "enum", "extension", "fallthrough", "false", "for", "func",
    "guard", "if", "import", "in", "init", "inout", "internal", "is", "let",
    "nil", "operator", "private", "protocol", "public", "repeat", "rethrows",
    "return", "self", "static", "struct", "subscript", "super", "switch",
    "throw", "throws", "true", "try", "typealias", "var", "where", "while",
}


class GenerationError(Exception):
    pass


def case_name(name: str) -> str:
    head, *rest = name.split("-")
    camel = head + "".join(part[:1].upper() + part[1:] for part in rest)
    return f"`{camel}`" if camel in SWIFT_KEYWORDS else camel


def swift_number(text: str, where: str) -> str:
    if not NUMBER.fullmatch(text.strip()):
        raise GenerationError(f"{where}: not a number: {text!r}")
    value = float(text)
    if value.is_integer():
        return str(int(value))
    return repr(value)


def number_list(text: str, where: str) -> list[str]:
    """Tokenises an SVG number list, accepting the compact forms SVG allows."""
    numbers: list[str] = []
    position = SEPARATORS.match(text, 0).end()
    while position < len(text):
        match = NUMBER.match(text, position)
        if not match:
            raise GenerationError(f"{where}: unexpected {text[position:]!r} in {text!r}")
        numbers.append(swift_number(match.group(), where))
        position = SEPARATORS.match(text, match.end()).end()
    return numbers


def load_svg(name: str, cache: Path | None) -> str | None:
    """Returns the SVG source, or None when the icon does not exist at the tag."""
    cached = cache / LUCIDE_TAG / f"{name}.svg" if cache else None
    if cached and cached.is_file():
        return cached.read_text(encoding="utf-8")
    url = RAW_URL.format(tag=LUCIDE_TAG, name=name)
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            source = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise GenerationError(f"{name}: HTTP {error.code} from {url}") from error
    except urllib.error.URLError as error:
        raise GenerationError(f"{name}: could not download {url}: {error.reason}") from error
    if cached:
        cached.parent.mkdir(parents=True, exist_ok=True)
        cached.write_text(source, encoding="utf-8")
    return source


def element_literal(element: ET.Element, where: str) -> str:
    if not element.tag.startswith(SVG_NS):
        raise GenerationError(f"{where}: element outside the SVG namespace: {element.tag}")
    tag = element.tag[len(SVG_NS):]
    if tag not in ELEMENTS:
        raise GenerationError(f"{where}: unsupported element <{tag}>")
    if len(element) or (element.text or "").strip():
        raise GenerationError(f"{where}: <{tag}> has unexpected content")
    where = f"{where} <{tag}>"
    attributes = dict(element.attrib)
    fill = attributes.pop("fill", "none")
    if fill not in FILL_VALUES:
        raise GenerationError(f"{where}: unsupported fill {fill!r}")
    literal = shape_literal(tag, attributes, where)
    return f".filled({literal})" if fill == "currentColor" else literal


def shape_literal(tag: str, attributes: dict[str, str], where: str) -> str:
    required, optional = ELEMENTS[tag]
    unknown = set(attributes) - set(required) - set(optional)
    if unknown:
        raise GenerationError(f"{where}: unsupported attribute(s) {sorted(unknown)}")
    missing = [key for key in required if key not in attributes]
    if missing:
        raise GenerationError(f"{where}: missing attribute(s) {missing}")
    values = {**optional, **attributes}

    def number(key: str) -> str:
        return swift_number(values[key], f"{where} {key}")

    if tag == "path":
        data = values["d"]
        if not PATH_DATA.fullmatch(data):
            raise GenerationError(f"{where}: unexpected path data {data!r}")
        return f'.path("{" ".join(data.split())}")'
    if tag == "circle":
        return f".circle(cx: {number('cx')}, cy: {number('cy')}, r: {number('r')})"
    if tag == "ellipse":
        return (f".ellipse(cx: {number('cx')}, cy: {number('cy')}, "
                f"rx: {number('rx')}, ry: {number('ry')})")
    if tag == "rect":
        corners = "".join(f", {key}: {number(key)}" for key in ("rx", "ry") if values[key] is not None)
        return (f".rect(x: {number('x')}, y: {number('y')}, "
                f"width: {number('width')}, height: {number('height')}{corners})")
    if tag == "line":
        return (f".line(x1: {number('x1')}, y1: {number('y1')}, "
                f"x2: {number('x2')}, y2: {number('y2')})")
    points = number_list(values["points"], f"{where} points")
    if len(points) < 4 or len(points) % 2:
        raise GenerationError(f"{where}: points needs at least two x,y pairs: {values['points']!r}")
    return f".{tag}([{', '.join(points)}])"


def icon_elements(name: str, source: str) -> list[str]:
    if "<!DOCTYPE" in source or "<!ENTITY" in source:
        raise GenerationError(f"{name}: DTDs and entities are not accepted")
    try:
        root = ET.fromstring(source)
    except ET.ParseError as error:
        raise GenerationError(f"{name}: invalid XML: {error}") from error
    if root.tag != f"{SVG_NS}svg":
        raise GenerationError(f"{name}: root element is {root.tag}, not <svg>")
    if root.attrib != ROOT_ATTRIBUTES:
        raise GenerationError(f"{name}: root attributes {root.attrib} differ from {ROOT_ATTRIBUTES}")
    literals = [element_literal(child, name) for child in root]
    if not literals:
        raise GenerationError(f"{name}: no drawable elements")
    return literals


def render(icons: dict[str, list[str]]) -> str:
    lines = [
        "// Generated by scripts/generate-lucide-icons.py. Do not edit by hand; re-run the script.",
        f"// Source: Lucide {LUCIDE_TAG} (commit {LUCIDE_COMMIT}),",
        "// https://github.com/lucide-icons/lucide, icons/<name>.svg. ISC License; see THIRD_PARTY_NOTICES.md.",
        "",
        "import CoreGraphics",
        "",
        "/// Lucide icons bundled with the app; the raw value is the Lucide icon name.",
        "/// Draw one with `LucideImage`.",
        "enum LucideIcon: String, CaseIterable {",
    ]
    for name in icons:
        lines.append(f'    case {case_name(name)} = "{name}"')
    lines += [
        "",
        "    /// The icon's SVG child elements, in Lucide's 24×24 viewBox.",
        "    var elements: [LucideElement] {",
        "        switch self {",
    ]
    for name, literals in icons.items():
        lines.append(f"        case .{case_name(name)}:")
        lines.append("            return [")
        lines += [f"                {literal}," for literal in literals]
        lines.append("            ]")
    lines += ["        }", "    }", "}", ""]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cache", type=Path, help="read and save SVGs under DIR/<tag>/")
    args = parser.parse_args()

    try:
        if len(set(ICONS)) != len(ICONS):
            raise GenerationError("ICONS has duplicate names")
        bad = [name for name in ICONS if not NAME.fullmatch(name)]
        if bad:
            raise GenerationError(f"not Lucide icon names: {bad}")
        cases = [case_name(name) for name in ICONS]
        if len(set(cases)) != len(cases):
            raise GenerationError("two icon names map to the same Swift case")

        icons: dict[str, list[str]] = {}
        missing: list[str] = []
        for name in ICONS:
            source = load_svg(name, args.cache)
            if source is None:
                missing.append(name)
            else:
                icons[name] = icon_elements(name, source)
        if missing:
            raise GenerationError(f"not found at Lucide {LUCIDE_TAG}: {', '.join(missing)}")
    except GenerationError as error:
        print(f"generate-lucide-icons: {error}", file=sys.stderr)
        return 1

    OUTPUT.write_text(render(icons), encoding="utf-8")
    print(f"Wrote {len(icons)} icons from Lucide {LUCIDE_TAG} to {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
