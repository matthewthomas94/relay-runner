#!/usr/bin/env python3
"""Report privacy-safe Option-to-audio timing from Relay speech diagnostics."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
from typing import Any


DEFAULT_LOG = os.environ.get("SPEECH_EVENT_LOG", "/tmp/relay_speech_events.jsonl")


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    parsed = [_finite_float(value) for value in values]
    if any(value is None for value in parsed):
        return None
    ordered = sorted(value for value in parsed if value is not None)
    index = max(0, math.ceil((percentile / 100) * len(ordered)) - 1)
    return round(ordered[index], 3)


def _finite_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def build_report(records: list[dict[str, Any]]) -> dict[str, Any]:
    by_command: dict[tuple[int, str], dict[str, float]] = {}
    by_play_request: dict[str, dict[str, float]] = {}
    by_utterance: dict[str, dict[str, Any]] = {}
    for record in records:
        event = str(record.get("event") or "")
        at = record.get("at")
        at = _finite_float(at)
        if at is None:
            continue
        command_key = None
        try:
            if isinstance(record["relay_command_seq"], bool):
                raise ValueError("boolean command sequence")
            command_key = (
                int(record["relay_command_seq"]),
                str(record["relay_command_id"]),
            )
        except (KeyError, TypeError, ValueError):
            pass
        if command_key is not None:
            by_command.setdefault(command_key, {})[event] = at
        play_request_id = str(record.get("play_request_id") or "")
        if play_request_id:
            by_play_request.setdefault(play_request_id, {})[event] = at
        utterance_id = str(record.get("utterance_id") or "")
        if utterance_id:
            sample = by_utterance.setdefault(utterance_id, {"utterance_id": utterance_id})
            sample[event] = at
            if command_key is not None:
                sample["command_key"] = command_key
            if play_request_id:
                sample["play_request_id"] = play_request_id

    samples: list[dict[str, Any]] = []
    stages = (
        "option_detected",
        "visual_play_acknowledged",
        "fifo_play_received",
        "retained_play_latched",
        "intent_committed",
        "tts_preparing",
        "first_wav_ready",
        "afplay_started",
    )
    for sample in by_utterance.values():
        if sample.get("command_key") is None or not sample.get("play_request_id"):
            continue
        command = by_command.get(sample.get("command_key"), {})
        request = by_play_request.get(sample.get("play_request_id"), {})
        timeline = {
            stage: sample.get(stage, request.get(stage, command.get(stage)))
            for stage in stages
        }
        if timeline["option_detected"] is None or timeline["afplay_started"] is None:
            continue
        durations = {
            "option_to_ack_ms": _delta(timeline, "option_detected", "visual_play_acknowledged"),
            "option_to_fifo_ms": _delta(timeline, "option_detected", "fifo_play_received"),
            "fifo_to_latch_ms": _delta(timeline, "fifo_play_received", "retained_play_latched"),
            "intent_wait_ms": max(
                0.0,
                _delta(timeline, "retained_play_latched", "intent_committed") or 0.0,
            ),
            "commit_to_preparing_ms": _delta(timeline, "intent_committed", "tts_preparing"),
            "preparing_to_wav_ms": _delta(timeline, "tts_preparing", "first_wav_ready"),
            "wav_to_afplay_ms": _delta(timeline, "first_wav_ready", "afplay_started"),
            "ack_to_first_audio_ms": _delta(
                timeline,
                "visual_play_acknowledged",
                "afplay_started",
            ),
            "option_to_first_audio_ms": _delta(timeline, "option_detected", "afplay_started"),
        }
        if durations["option_to_first_audio_ms"] is not None:
            samples.append({**sample, **durations})

    audio = [sample["option_to_first_audio_ms"] for sample in samples]
    acknowledgements = [
        sample["option_to_ack_ms"]
        for sample in samples
        if sample["option_to_ack_ms"] is not None
    ]
    acknowledgement_to_audio = [
        sample["ack_to_first_audio_ms"]
        for sample in samples
        if sample["ack_to_first_audio_ms"] is not None
    ]
    return {
        "sample_count": len(samples),
        "option_to_first_audio_p95_ms": _percentile(audio, 95),
        "option_to_ack_p95_ms": _percentile(acknowledgements, 95),
        "ack_to_first_audio_p95_ms": _percentile(acknowledgement_to_audio, 95),
        "samples": samples,
    }


def _delta(timeline: dict[str, float | None], start: str, end: str) -> float | None:
    started_at = _finite_float(timeline[start])
    ended_at = _finite_float(timeline[end])
    if started_at is None or ended_at is None or ended_at < started_at:
        return None
    delta = (ended_at - started_at) * 1000
    return round(delta, 3) if math.isfinite(delta) else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", nargs="?", default=DEFAULT_LOG)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    path = Path(args.log)
    records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    report = build_report(records)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"samples: {report['sample_count']}")
        print(f"Option to acknowledgement p95: {report['option_to_ack_p95_ms']} ms")
        print(f"Acknowledgement to first audio p95: {report['ack_to_first_audio_p95_ms']} ms")
        print(f"Option to first audio p95: {report['option_to_first_audio_p95_ms']} ms")
        for sample in report["samples"]:
            print(json.dumps(sample, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
