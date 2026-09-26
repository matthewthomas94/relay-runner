#!/usr/bin/env python3
"""Read-only warm-service latency measurement; starts/stops its own service."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import select
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "services"))
from laya_qualification import qualify_for_bridge


def measure(args, checkpoint):
    corpus_bytes = Path(args.corpus).read_bytes()
    corpus = json.loads(corpus_bytes)
    cases = corpus["cases"] if isinstance(corpus, dict) else corpus
    with tempfile.TemporaryDirectory(prefix="rr-laya-ipc-") as folder:
        socket_path = str(Path(folder) / "service.sock")
        with (Path(folder) / "server.stderr").open("w+") as errors:
            start = time.perf_counter()
            process = subprocess.Popen(
                [sys.executable, str(ROOT / "scripts/relay-laya-qualify"), "serve",
                 "--checkpoint", checkpoint, "--model-dir", str(Path(args.model_root) / checkpoint),
                 "--socket", socket_path],
                stdout=subprocess.PIPE, stderr=errors, text=True,
            )
            try:
                ready, _, _ = select.select([process.stdout], [], [], 60)
                line = process.stdout.readline() if ready else ""
                if not line:
                    errors.seek(0)
                    raise RuntimeError("Local service did not become ready: " + errors.read())
                identity = json.loads(line)
                startup_ms = (time.perf_counter() - start) * 1000
                os.environ.update(RELAY_LAYA_TEST_MODE="1", RELAY_LAYA_SOCKET=socket_path, RELAY_LAYA_TIMEOUT_MS="100")
                # Exclude several warm client requests from reported samples.
                for index in range(3):
                    qualify_for_bridge("Open the browser.", {"relay_command_id": f"warm-{index}", "relay_command_seq": index})
                results = []
                for index, case in enumerate(cases):
                    for repeat in range(args.repeats):
                        command = {"relay_command_id": f"{case['id']}:{repeat}", "relay_command_seq": index * args.repeats + repeat + 10}
                        start = time.perf_counter()
                        result = qualify_for_bridge(case["text"], command, case.get("context", []))
                        elapsed = (time.perf_counter() - start) * 1000
                        results.append({"id": case["id"], "repeat": repeat, "elapsed_ms": elapsed, "result": result})
                times = sorted(row["elapsed_ms"] for row in results)
                return {
                    "checkpoint": checkpoint, "model": identity["model"], "startup_until_ready_ms": startup_ms,
                    "corpus_sha256": hashlib.sha256(corpus_bytes).hexdigest(), "samples": len(times),
                    "p50_ms": statistics.median(times), "p95_ms": times[__import__("math").ceil(len(times) * .95) - 1],
                    "max_ms": max(times),
                    "fallback_reasons": dict(Counter(row["result"].get("fallback_reason") for row in results if row["result"].get("fallback_reason"))),
                    "results": results,
                }
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-root", required=True)
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--checkpoints", nargs="+", choices=("english", "multilingual"), default=["english", "multilingual"])
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("repeats must be positive")
    measurements = [measure(args, name) for name in args.checkpoints]
    report = {
        "experiment": "RR-379", "timing_boundary": "Actual bridge client call including serialization, Unix socket IPC, warmed local inference, deserialization and guards; excludes Messenger, PM, STT and TTS.",
        "test_mode_only": True, "services_stopped_after_measurement": True,
        "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT / "services/laya_qualification.py", ROOT / "scripts/relay-laya-qualify", Path(__file__).resolve())},
        "measurements": measurements,
    }
    Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps([{key: value for key, value in result.items() if key != "results"} for result in measurements], indent=2))


if __name__ == "__main__":
    main()
