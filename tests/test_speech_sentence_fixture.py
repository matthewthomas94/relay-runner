"""The sentence fixture the Rust speech service is tested against (RR-481).

`rust/relay-speech/tests/sentences.json` holds what `_sentence_chunks` in
services/tts_worker.py makes of the RR-479 corpus and of a few edge cases. The
Rust splitter's unit test reads the same file, so this test keeps both splitters
tied to the Python one. Regenerate the file after a deliberate change with

    python3 tests/test_speech_sentence_fixture.py --write
"""

from __future__ import annotations

import json
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "services"))

from tts_worker import _sentence_chunks  # noqa: E402

CORPUS = ROOT / "rust" / "relay-speech-proto" / "corpus.tsv"
FIXTURE = ROOT / "rust" / "relay-speech" / "tests" / "sentences.json"

EDGE_CASES = [
    "",
    "   \n\t  ",
    "No terminator at all",
    "One.\n\nTwo?  Three",
    "Wait... what?! Really?!\" Yes.",
    "He said \"stop.\" Then he left.",
    "(See the note.) Next one.",
    "A list [item one.] and more.",
    "It's 5.5 seconds, or 2.5 at most.",
    "Version 0.5.3 ships today. See v2.0.0-rc.15 too.",
    "Ends with a closer.'",
    "Stray .dots in.the middle",
    "Mixed?!.' punctuation. Done",
    "Tabs\tand non-breaking spaces. Next line.",
    "File\x1cseparator. Kept",
    "Unicode “quotes.” and… an ellipsis… done.",
    "Ends with many dots...",
    "?! Leading terminators.",
]


def corpus_texts() -> list[str]:
    texts = []
    for line in CORPUS.read_text().splitlines():
        if line.strip():
            texts.append(line.split("\t", 2)[2].strip())
    return texts


def cases() -> list[dict]:
    texts = corpus_texts()
    inputs = texts + [" ".join(texts), "\n".join(texts)] + EDGE_CASES
    return [{"text": text, "chunks": _sentence_chunks(text)} for text in inputs]


def render() -> str:
    return json.dumps({
        "source": "services/tts_worker.py _sentence_chunks; regenerate with "
                  "python3 tests/test_speech_sentence_fixture.py --write",
        "cases": cases(),
    }, indent=1, ensure_ascii=False) + "\n"


class SentenceFixtureTests(unittest.TestCase):
    def test_fixture_matches_the_python_splitter(self):
        self.assertEqual(json.loads(FIXTURE.read_text()), json.loads(render()))

    def test_fixture_covers_the_whole_corpus(self):
        self.assertEqual(len(corpus_texts()), 57)


if __name__ == "__main__":
    if sys.argv[1:] == ["--write"]:
        FIXTURE.parent.mkdir(parents=True, exist_ok=True)
        FIXTURE.write_text(render())
        print(f"wrote {FIXTURE.relative_to(ROOT)}")
    else:
        unittest.main()
