"""GRID corpus helpers: word-level segments from align files.

GRID align times are in 1/25000 s units; low-res video is 25 fps, so frame
index = t / 1000. Each 3 s clip is "<command> <colour> <preposition> <letter>
<digit> <adverb>", which gives closed vocabularies of 4, 4, 4, 25, 10, 4 words.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

COMMANDS = {"bin", "lay", "place", "set"}
COLOURS = {"blue", "green", "red", "white"}
DIGITS = {"zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"}
ADVERBS = {"again", "now", "please", "soon"}
VOCABS = {"commands": COMMANDS, "colours": COLOURS, "digits": DIGITS, "adverbs": ADVERBS}


@dataclass
class WordSpan:
    word: str
    start_frame: int
    end_frame: int  # exclusive


def read_align(path: Path, fps: float = 25.0) -> list[WordSpan]:
    spans = []
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        s, e, w = int(parts[0]), int(parts[1]), parts[2]
        if w in ("sil", "sp"):
            continue
        spans.append(WordSpan(w, round(s / 25000 * fps), round(e / 25000 * fps)))
    return spans
