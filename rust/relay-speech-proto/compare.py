#!/usr/bin/env python3
"""Render the corpus with the Python speech stack and the Rust prototype,
measure both, and write a side-by-side listening page (RR-479).

Run it with the services venv's interpreter, which has kokoro_onnx, after
`cargo build --release --locked --target aarch64-apple-darwin` in this directory:

    "$HOME/Library/Application Support/relay-runner/services/.venv/bin/python" \\
        rust/relay-speech-proto/compare.py --out /a/directory/outside/the/repo

Stages, all run by default and each resumable (a finished run is not repeated):

    render       every stack and voice over the whole corpus, one process each
                 under `/usr/bin/time -l`, the stacks taking turns per voice
    first-audio  a one-sentence reply: cold (process start to the WAV being
                 written) and warm (same process, model already loaded)
    coreml       the Rust prototype again with the CoreML execution provider
    page         results.json and index.html from whatever the stages left

Everything is written under --out: audio/<stack>/<voice>/<id>.wav, runs/, and
the two files above.

Scheduling priority decides the timings. The app starts its speech bridge as a
launchd job, which runs at priority 20 on any core; an orchestrator worker runs
at background priority 4, which macOS keeps on the efficiency cores, three to
four times slower here. Every record carries the priority it was taken at. To measure
as the bridge runs, start this script the way the bridge is started and remove
the job when it has finished:

    launchctl submit -l com.relay.rr479-measure -o LOG -e LOG -- /bin/sh -c \
        '"$0" "$1" --out "$2"; launchctl remove com.relay.rr479-measure' PYTHON SCRIPT OUT
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import statistics
import subprocess
import sys
import time
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
BINARY = HERE / "target/aarch64-apple-darwin/release/relay-speech-proto"
MODELS = Path.home() / ".local/share/kokoro"
VOICES = ["am_puck", "bm_george", "bf_isabella", "af_sky"]
FIRST_AUDIO_ID = "reply-02"
BRIDGE_PRIORITY = 20

# Each stack: label for the page, and how to start it. `python` is today's
# stack; the others are the Rust prototype with one of its two phonemisers.
STACKS = {
    "python": "Python: kokoro-onnx, espeak-ng",
    "misaki": "Rust: misaki-rs, no fallback",
    "loqui": "Rust: loqui-g2p",
    "loqui-gb": "Rust: loqui-g2p, British lexicon",
}


def command(stack: str, corpus: Path, voice: str, out: Path, provider: str = "cpu") -> list[str]:
    if stack == "python":
        return [sys.executable, str(Path(__file__).resolve()), "--python-child", str(corpus), voice, str(out)]
    g2p, _, lang = stack.partition("-")
    return [str(BINARY), "--corpus", str(corpus), "--voice", voice, "--out", str(out),
            "--g2p", g2p, "--lang", lang or "us", "--provider", provider]


def python_child(corpus: Path, voice: str, out: Path) -> None:
    """Today's stack, called the way services/tts_worker.py calls it."""
    started = time.perf_counter()
    import numpy as np
    from kokoro_onnx import Kokoro
    imported = time.perf_counter()
    kokoro = Kokoro(str(MODELS / "kokoro-v1.0.onnx"), str(MODELS / "voices-v1.0.bin"))
    print(f"load\timport_ms={1000 * (imported - started):.1f}\tmodel_ms={1000 * (time.perf_counter() - imported):.1f}")
    out.mkdir(parents=True, exist_ok=True)
    for line in corpus.read_text().splitlines():
        sentence_id, _, text = line.split("\t", 2)
        started = time.perf_counter()
        phonemes = kokoro.tokenizer.phonemize(text, "en-us")
        phonemized = time.perf_counter()
        # create() with is_phonemes skips only the phonemize() call just made.
        samples, rate = kokoro.create(phonemes, voice=voice, speed=1.0, lang="en-us", is_phonemes=True)
        synthesized = time.perf_counter()
        with wave.open(str(out / f"{sentence_id}.wav"), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(rate)
            wav.writeframes((np.clip(samples, -1, 1) * 32767).astype(np.int16).tobytes())
        print(f"sentence\t{sentence_id}\t{1000 * (phonemized - started):.1f}"
              f"\t{1000 * (synthesized - phonemized):.1f}\t{len(samples) / rate:.3f}\t\t{phonemes}", flush=True)


def priority() -> int:
    """This process's scheduling priority, which its children inherit."""
    return int(subprocess.check_output(["/bin/ps", "-o", "pri=", "-p", str(os.getpid())]))


def parse_run(text: str) -> dict:
    run = {"load": {}, "sentences": {}}
    for line in text.splitlines():
        fields = line.split("\t")
        if fields[0] == "load":
            run["load"] = {key: float(value) for key, value in (field.split("=") for field in fields[1:])}
        elif fields[0] == "sentence":
            run["sentences"][fields[1]] = {
                "g2p_ms": float(fields[2]), "synth_ms": float(fields[3]), "audio_s": float(fields[4]),
                "unknown": fields[5].split(), "phonemes": fields[6],
            }
    return run


def timed_run(name: str, argv: list[str], runs: Path, timeout: int = 3600) -> None:
    """Run argv under `/usr/bin/time -l`, keeping stdout, the time report and the load."""
    if (runs / f"{name}.json").exists():
        return
    load = os.getloadavg()[0]
    started = time.perf_counter()
    try:
        done = subprocess.run(["/usr/bin/time", "-l", *argv], capture_output=True, text=True, timeout=timeout)
        status, stdout, stderr = done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired as expired:
        status, stdout, stderr = "timeout", expired.stdout or "", expired.stderr or ""
        stdout, stderr = (s.decode() if isinstance(s, bytes) else s for s in (stdout, stderr))
    memory = {key: int(match.group(1)) for key, pattern in (
        ("max_rss_bytes", r"(\d+)\s+maximum resident set size"),
        ("peak_footprint_bytes", r"(\d+)\s+peak memory footprint"),
    ) if (match := re.search(pattern, stderr))}
    record = {"status": status, "wall_s": time.perf_counter() - started, "load_average_before": load,
              "priority": priority(),
              "stderr_tail": stderr.strip().splitlines()[:3] if status else [], **memory, **parse_run(stdout)}
    (runs / f"{name}.json").write_text(json.dumps(record, indent=1, ensure_ascii=False))
    print(f"{name}: status {status}, {record['wall_s']:.0f} s, load {load:.1f}", flush=True)


def stage_render(out: Path, corpus: Path) -> None:
    for voice in VOICES:
        for stack in STACKS:
            if stack == "loqui-gb" and not voice.startswith("b"):
                continue
            timed_run(f"render-{stack}-{voice}", command(stack, corpus, voice, out / "audio" / stack / voice), out / "runs")


def stage_first_audio(out: Path, corpus: Path) -> None:
    runs = out / "runs"
    if (runs / "first-audio.json").exists():
        return
    line = next(line for line in corpus.read_text().splitlines() if line.startswith(FIRST_AUDIO_ID + "\t"))
    once, repeated = runs / "first-audio-1.tsv", runs / "first-audio-11.tsv"
    once.write_text(line + "\n")
    repeated.write_text("".join(f"{line.replace(FIRST_AUDIO_ID, f'{FIRST_AUDIO_ID}-{n}', 1)}\n" for n in range(11)))
    result = {stack: {"cold_s": [], "warm_ms": []} for stack in ("python", "loqui", "misaki")}
    for _ in range(5):  # the stacks take turns, so load spikes hit them alike
        for stack, numbers in result.items():
            started = time.perf_counter()
            child = subprocess.Popen(command(stack, once, VOICES[0], runs / "scratch"), stdout=subprocess.PIPE, text=True)
            for output in child.stdout:
                if output.startswith("sentence\t"):  # printed once the WAV is on disk
                    numbers["cold_s"].append(time.perf_counter() - started)
            child.wait()
    for stack, numbers in result.items():
        done = subprocess.run(command(stack, repeated, VOICES[0], runs / "scratch"), capture_output=True, text=True, check=True)
        sentences = list(parse_run(done.stdout)["sentences"].values())
        numbers["warm_ms"] = [sentence["g2p_ms"] + sentence["synth_ms"] for sentence in sentences[1:]]
        numbers["audio_s"] = sentences[0]["audio_s"]
        numbers["priority"] = priority()
    (runs / "first-audio.json").write_text(json.dumps(result, indent=1))


def stage_coreml(out: Path, corpus: Path) -> None:
    voice = VOICES[0]
    timed_run(f"coreml-loqui-{voice}", command("loqui", corpus, voice, out / "audio" / "coreml" / voice, "coreml"),
              out / "runs", timeout=1800)


# espeak-ng writes IPA; misaki writes Kokoro's own alphabet. This approximates
# the first in the second, after the table misaki uses for its espeak fallback,
# so that the distance below counts pronunciation and not notation.
ESPEAK_TO_MISAKI = [
    ("aɪ", "I"), ("aʊ", "W"), ("dʒ", "ʤ"), ("eɪ", "A"), ("oʊ", "O"), ("əʊ", "Q"), ("tʃ", "ʧ"), ("ɔɪ", "Y"),
    ("ɚ", "əɹ"), ("ɝ", "ɜɹ"), ("ɐ", "ə"), ("ɪə", "iə"), ("ː", ""), ("əl", "ᵊl"), ("e", "A"), ("o", "ɔ"),
    ("r", "ɹ"), ("ɾ", "T"), ("ʔ", "t"),
]


def comparable(phonemes: str, espeak: bool) -> str:
    if espeak:
        for old, new in ESPEAK_TO_MISAKI:
            phonemes = phonemes.replace(old, new)
    return re.sub(r"[ˈˌ\s]", "", phonemes)  # stress and spacing are not compared


def distance(a: str, b: str) -> float:
    """Levenshtein distance over the longer length: 0 identical, 1 nothing shared."""
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        previous, row[0] = row[0], i
        for j, y in enumerate(b, 1):
            previous, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, previous + (x != y))
    return row[-1] / max(len(a), len(b), 1)


def summarise(out: Path, corpus: Path) -> dict:
    runs = {path.stem: json.loads(path.read_text()) for path in sorted((out / "runs").glob("*.json"))}
    first_audio = runs.pop("first-audio", None)
    rows = []
    for name, run in runs.items():
        kind, stack, voice = re.fullmatch(r"(render|coreml)-(.+)-([a-z]{2}_[a-z]+)", name).groups()
        sentences = run["sentences"].values()
        audio = sum(sentence["audio_s"] for sentence in sentences)
        compute = sum(sentence["g2p_ms"] + sentence["synth_ms"] for sentence in sentences) / 1000
        rows.append({
            "run": name, "kind": kind, "stack": stack, "voice": voice, "status": run["status"],
            "sentences": len(run["sentences"]), "load_ms": run["load"], "audio_s": round(audio, 1),
            "real_time_factor": round(compute / audio, 3) if audio else None,
            "g2p_ms_mean": round(statistics.mean(s["g2p_ms"] for s in sentences), 1) if sentences else None,
            "max_rss_mb": round(run.get("max_rss_bytes", 0) / 2**20), "wall_s": round(run["wall_s"]),
            "peak_footprint_mb": round(run.get("peak_footprint_bytes", 0) / 2**20),
            "load_average_before": round(run["load_average_before"], 1), "stderr_tail": run["stderr_tail"],
            "priority": run.get("priority"),
        })
    sentences = []
    for line in corpus.read_text().splitlines():
        sentence_id, category, text = line.split("\t", 2)
        phonemes = {stack: runs.get(f"render-{stack}-{'bm_george' if stack == 'loqui-gb' else VOICES[0]}", {})
                    .get("sentences", {}).get(sentence_id, {}) for stack in STACKS}
        python = comparable(phonemes["python"].get("phonemes", ""), espeak=True)
        sentences.append({
            "id": sentence_id, "category": category, "text": text,
            "phonemes": {stack: entry.get("phonemes", "") for stack, entry in phonemes.items()},
            "dropped_by_misaki": phonemes["misaki"].get("unknown", []),
            "distance": {stack: round(distance(python, comparable(phonemes[stack].get("phonemes", ""), espeak=False)), 3)
                         for stack in ("misaki", "loqui")},
        })
    if first_audio:
        for numbers in first_audio.values():
            numbers["cold_s_median"] = round(statistics.median(numbers["cold_s"]), 2)
            numbers["warm_ms_median"] = round(statistics.median(numbers["warm_ms"]))
    return {
        "binary_bytes": BINARY.stat().st_size, "first_audio": first_audio, "runs": rows, "sentences": sentences,
        "most_different": [s["id"] for s in sorted(sentences, key=lambda s: -s["distance"]["loqui"])[:12]],
    }


PAGE_STYLE = """
body { font: 15px/1.45 -apple-system, sans-serif; margin: 2rem auto; max-width: 1180px; padding: 0 1rem; color: #1d1d1f; }
h1 { font-size: 1.5rem; } h2 { font-size: 1.1rem; margin: 0 0 .3rem; }
section { border: 1px solid #d2d2d7; border-radius: 10px; padding: 1rem; margin: 1rem 0; }
section.flag { border-color: #bf5700; border-width: 2px; }
.badge { background: #bf5700; color: #fff; border-radius: 5px; padding: 1px 7px; font-size: .78rem; margin-left: .5rem; }
.text { font-size: 1.05rem; margin: .2rem 0 .6rem; }
table { border-collapse: collapse; width: 100%; } th, td { text-align: left; padding: 3px 8px 3px 0; vertical-align: middle; }
th { font-weight: 600; font-size: .82rem; color: #6e6e73; }
.phonemes td { font-family: ui-monospace, Menlo, monospace; font-size: .82rem; } .note { color: #6e6e73; font-size: .85rem; }
audio { height: 30px; width: 215px; } .dropped { color: #b00020; }
"""


def render_page(out: Path, summary: dict) -> None:
    most_different = summary["most_different"]
    by_id = {sentence["id"]: sentence for sentence in summary["sentences"]}
    escape = html.escape
    parts = [
        "<!doctype html><meta charset='utf-8'><title>RR-479: Kokoro in Rust, listening page</title>",
        f"<style>{PAGE_STYLE}</style><h1>Kokoro speech: today's Python stack against the Rust prototype</h1>",
        "<p>Every sentence of the corpus, in all four voices. The first player in each row is what Relay Runner "
        "says today (kokoro-onnx with espeak-ng phonemes). The others are the Rust prototype with the same model "
        "and voice files and a non-GPL phonemiser: <b>misaki-rs</b> without its espeak fallback, which leaves a word "
        "it does not know unspoken, and <b>loqui-g2p</b>, which pronounces such a word with a small neural model. "
        "British voices have a fourth player: loqui-g2p with its British lexicon; every other player uses American "
        "phonemes for all voices, as the app does today.</p>",
        "<p class='note'>The distance beside each Rust phoneme line is how far it is from the Python line (0 the same, "
        "1 nothing in common), after writing espeak's IPA in Kokoro's alphabet and ignoring stress and spacing.</p>",
        "<h2>Start here: the sentences whose phonemes differ most</h2><p>",
        " · ".join(f"<a href='#{i}'>{i}</a> ({by_id[i]['distance']['loqui']:.2f})" for i in most_different),
        "</p><h2>Sentences where misaki-rs leaves words unspoken</h2><p>",
        " · ".join(f"<a href='#{s['id']}'>{s['id']}</a> <span class='dropped'>{escape(' '.join(s['dropped_by_misaki']))}</span>"
                   for s in summary["sentences"] if s["dropped_by_misaki"]),
        "</p>",
    ]
    for sentence in summary["sentences"]:
        sentence_id, phonemes = sentence["id"], sentence["phonemes"]
        flagged = sentence_id in most_different
        parts.append(f"<section id='{sentence_id}' class='{'flag' if flagged else ''}'><h2>{sentence_id}"
                     f"{'<span class=badge>differs most</span>' if flagged else ''}</h2>"
                     f"<div class='text'>{escape(sentence['text'])}</div><table class='phonemes'>")
        for stack, label in STACKS.items():
            score = sentence["distance"].get(stack)
            dropped = sentence["dropped_by_misaki"] if stack == "misaki" else []
            parts.append(f"<tr><th>{escape(label)}</th><td>{escape(phonemes[stack])}"
                         f"{f' <span class=note>distance {score:.2f}</span>' if score is not None else ''}"
                         f"{' <span class=dropped>unspoken: ' + escape(' '.join(dropped)) + '</span>' if dropped else ''}</td></tr>")
        parts.append("</table><table><tr><th>Voice</th>" + "".join(f"<th>{escape(label)}</th>" for label in STACKS.values()) + "</tr>")
        for voice in VOICES:
            parts.append(f"<tr><td>{voice}</td>")
            for stack in STACKS:
                path = Path("audio") / stack / voice / f"{sentence_id}.wav"
                if stack == "misaki" and phonemes["misaki"] == phonemes["loqui"]:
                    parts.append("<td class='note'>same phonemes as loqui-g2p</td>")
                elif (out / path).exists():
                    parts.append(f"<td><audio controls preload='none' src='{path}'></audio></td>")
                else:
                    parts.append("<td></td>")
            parts.append("</tr>")
        parts.append("</table></section>")
    (out / "index.html").write_text("\n".join(parts))


def main() -> None:
    if len(sys.argv) == 5 and sys.argv[1] == "--python-child":
        return python_child(Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]))
    stages = {"render": stage_render, "first-audio": stage_first_audio, "coreml": stage_coreml}
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, required=True, help="directory outside the repository")
    parser.add_argument("--corpus", type=Path, default=HERE / "corpus.tsv")
    parser.add_argument("--stage", action="append", choices=[*stages, "page"], help="default: all of them")
    arguments = parser.parse_args()
    out = arguments.out.resolve()
    (out / "runs").mkdir(parents=True, exist_ok=True)
    if priority() < BRIDGE_PRIORITY:
        print(f"warning: running at priority {priority()}, below the speech bridge's {BRIDGE_PRIORITY}; "
              "timings will be slower than the app's (see this script's docstring)", flush=True)
    for stage in arguments.stage or [*stages, "page"]:
        if stage in stages:
            stages[stage](out, arguments.corpus)
    summary = summarise(out, arguments.corpus)
    (out / "results.json").write_text(json.dumps(summary, indent=1, ensure_ascii=False))
    render_page(out, summary)
    print(f"wrote {out / 'index.html'} and {out / 'results.json'}")


if __name__ == "__main__":
    main()
