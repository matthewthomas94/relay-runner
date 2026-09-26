#!/usr/bin/env python3
"""Read-only comparison of the fixed legacy router and current qualification.

Only classifies text: no provider, email, desktop, ticket or dispatch calls.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time
import types

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))
from command_actions import classify_command
from intent_qualification import qualify_intent

LEGACY_REF = "09b0885b68761156127143debc03031761749e01"


def legacy_classifier(ref: str):
    source = subprocess.check_output(
        ["git", "show", f"{ref}:services/command_actions.py"], cwd=ROOT, text=True,
    )
    module = types.ModuleType("legacy_command_actions")
    sys.modules[module.__name__] = module
    exec(compile(source, f"git:{ref}:services/command_actions.py", "exec"), module.__dict__)
    return module.classify_command


def legacy_bucket(action) -> str | None:
    if action.kind == "control":
        return None
    if action.kind == "direct_action":
        return "action"
    if action.kind in {"create_ticket", "update_ticket", "dispatch_ticket", "inline_work", "needs_project"}:
        return "task"
    return "discussion"


def evaluate(cases: list[dict], classifier, *, framework: bool, repeats: int) -> dict:
    results, timings = [], []
    for case in cases:
        for _ in range(repeats):
            start = time.perf_counter_ns()
            action = classifier(case["text"])
            hint = qualify_intent(
                case["text"], context=case.get("context", []),
                action_kind=action.kind, action_reason=action.reason,
            ) if framework else None
            bucket = hint.bucket if hint else legacy_bucket(action)
            timings.append((time.perf_counter_ns() - start) / 1_000_000)
        results.append({
            "id": case["id"], "expected_bucket": case["expected_bucket"], "bucket": bucket,
            "expected_action_kind": case.get("expected_action_kind"), "action_kind": action.kind,
            "unresolved": hint.unresolved if hint else None,
            "bucket_correct": bucket == case["expected_bucket"],
            "action_correct": action.kind == case["expected_action_kind"] if "expected_action_kind" in case else None,
            "resolution_correct": hint.unresolved == case["expected_needs_resolution"] if hint and "expected_needs_resolution" in case else None,
        })
    confusion = Counter(f"{row['expected_bucket']} -> {row['bucket']}" for row in results)
    errors = [row for row in results if not row["bucket_correct"] or row["action_correct"] is False or row["resolution_correct"] is False]
    ordered = sorted(timings)
    return {
        "cases": len(cases), "repeats": repeats,
        "bucket_errors": sum(not row["bucket_correct"] for row in results),
        "action_kind_scored": sum(row["action_correct"] is not None for row in results),
        "action_kind_errors": sum(row["action_correct"] is False for row in results),
        "resolution_errors": sum(row["resolution_correct"] is False for row in results),
        "false_task_or_action": sum(row["bucket"] in {"task", "action"} and not row["bucket_correct"] for row in results),
        "discussion_to_task_or_action": sum(row["expected_bucket"] == "discussion" and row["bucket"] in {"task", "action"} for row in results),
        "task_action_confusion": sum({row["expected_bucket"], row["bucket"]} == {"task", "action"} for row in results),
        "confusion": dict(confusion),
        "qualification_only_ms": {"p50": statistics.median(ordered), "p95": ordered[min(len(ordered)-1, int(len(ordered)*.95))]},
        "errors": errors, "results": results,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=ROOT / "tests/fixtures/intent_qualification.json")
    parser.add_argument("--legacy-ref", default=LEGACY_REF)
    parser.add_argument("--repeats", type=int, default=100)
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be positive")
    corpus = json.loads(args.corpus.read_text())
    cases = corpus["cases"]
    if not cases:
        parser.error("corpus contains no cases")
    print(json.dumps({
        "provenance": corpus.get("provenance"), "corpus": str(args.corpus),
        "splits": dict(Counter(case.get("split", "unspecified") for case in cases)),
        "machine": platform.platform(), "python": platform.python_version(),
        "legacy_ref": args.legacy_ref,
        "timing_scope": "Warm text classification only; excludes STT, Messenger, PM, transport and action execution.",
        "legacy": evaluate(cases, legacy_classifier(args.legacy_ref), framework=False, repeats=args.repeats),
        "framework": evaluate(cases, classify_command, framework=True, repeats=args.repeats),
    }, indent=2))


if __name__ == "__main__":
    main()
