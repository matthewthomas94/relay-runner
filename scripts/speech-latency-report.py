#!/usr/bin/env python3
"""Correlate terminal delivery acknowledgement to real audio playback."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
from typing import Any


DEFAULT_LOG = os.environ.get("SPEECH_EVENT_LOG", "/tmp/relay_speech_events.jsonl")
DEFAULT_DELIVERY_LOG = os.environ.get(
    "RELAY_TERMINAL_DELIVERY_EVENTS",
    "/tmp/relay_terminal_delivery_events.jsonl",
)


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


def _command_key(record: dict[str, Any]) -> tuple[int, str] | None:
    try:
        sequence = record["relay_command_seq"]
        if isinstance(sequence, bool):
            return None
        command_id = str(record["relay_command_id"] or "").strip()
        if not command_id:
            return None
        return int(sequence), command_id
    except (KeyError, TypeError, ValueError):
        return None


def build_report(
    speech_records: list[dict[str, Any]],
    delivery_records: list[dict[str, Any]],
) -> dict[str, Any]:
    acknowledgements: dict[tuple[int, str], list[dict[str, Any]]] = {}
    for record in delivery_records:
        if str(record.get("event") or "") != "provider_acknowledged":
            continue
        command_key = _command_key(record)
        acknowledged_at = _finite_float(record.get("timestamp"))
        provider = str(record.get("provider") or "").strip().lower()
        if command_key is None or acknowledged_at is None or provider not in {"codex", "claude"}:
            continue
        acknowledgements.setdefault(command_key, []).append({
            "provider": provider,
            "provider_acknowledged": acknowledged_at,
        })

    by_command: dict[tuple[int, str], dict[str, float]] = {}
    by_play_request: dict[str, dict[str, float]] = {}
    by_utterance: dict[str, dict[str, Any]] = {}
    playback_counts: dict[tuple[tuple[int, str], str, str], int] = {}
    for record in speech_records:
        event = str(record.get("event") or "")
        at = record.get("at")
        at = _finite_float(at)
        if at is None:
            continue
        command_key = _command_key(record)
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
            if event == "afplay_started" and command_key is not None and play_request_id:
                playback_key = (command_key, play_request_id, utterance_id)
                playback_counts[playback_key] = playback_counts.get(playback_key, 0) + 1

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
        command_key = sample["command_key"]
        command = by_command.get(command_key, {})
        request = by_play_request.get(sample.get("play_request_id"), {})
        terminal_acknowledgements = acknowledgements.get(command_key, [])
        playback_key = (
            command_key,
            sample["play_request_id"],
            sample["utterance_id"],
        )
        if len(terminal_acknowledgements) != 1 or playback_counts.get(playback_key) != 1:
            continue
        timeline = {
            stage: sample.get(stage, request.get(stage, command.get(stage)))
            for stage in stages
        }
        timeline["provider_acknowledged"] = terminal_acknowledgements[0][
            "provider_acknowledged"
        ]
        if timeline["afplay_started"] is None:
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
                "provider_acknowledged",
                "afplay_started",
            ),
            "option_to_first_audio_ms": _delta(timeline, "option_detected", "afplay_started"),
        }
        if durations["ack_to_first_audio_ms"] is not None:
            samples.append({
                **sample,
                "provider": terminal_acknowledgements[0]["provider"],
                "provider_acknowledged": timeline["provider_acknowledged"],
                **durations,
            })

    audio = [
        sample["option_to_first_audio_ms"]
        for sample in samples
        if sample["option_to_first_audio_ms"] is not None
    ]
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
    provider_sample_counts = {
        provider: sum(sample["provider"] == provider for sample in samples)
        for provider in ("codex", "claude")
    }
    return {
        "sample_count": len(samples),
        "provider_sample_counts": provider_sample_counts,
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
    parser.add_argument("speech_log", nargs="?", default=DEFAULT_LOG)
    parser.add_argument("--delivery-log", default=DEFAULT_DELIVERY_LOG)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    speech_path = Path(args.speech_log)
    delivery_path = Path(args.delivery_log)
    speech_records = [
        json.loads(line) for line in speech_path.read_text().splitlines() if line.strip()
    ]
    delivery_records = [
        json.loads(line) for line in delivery_path.read_text().splitlines() if line.strip()
    ]
    report = build_report(speech_records, delivery_records)
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
