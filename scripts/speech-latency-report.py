#!/usr/bin/env python3
"""Correlate authoritative playback realization to real audio playback."""

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
MESSENGER_STAGES = (
    "user_turn_received",
    "messenger_submitted",
    "messenger_provider_started",
    "messenger_first_semantic_output",
    "tts_enqueued",
    "queued",
    "afplay_started",
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
    playback_by_utterance: dict[str, list[dict[str, Any]]] = {}
    authoritative_playback_identities: dict[
        tuple[int, str], set[tuple[str, str]]
    ] = {}
    authoritative_lifecycle_counts: dict[
        tuple[tuple[int, str], str], dict[str, int]
    ] = {}
    for record in speech_records:
        event = str(record.get("event") or "")
        command_key = _command_key(record)
        if (
            event == "afplay_started"
            and record.get("authoritative") is True
            and command_key is not None
        ):
            authoritative_playback_identities.setdefault(command_key, set()).add((
                str(record.get("utterance_id") or ""),
                str(record.get("play_request_id") or ""),
            ))
        at = record.get("at")
        at = _finite_float(at)
        if at is None:
            continue
        play_request_id = str(record.get("play_request_id") or "")
        utterance_id = str(record.get("utterance_id") or "")
        if command_key is not None and not utterance_id:
            by_command.setdefault(command_key, {})[event] = at
        if play_request_id and not utterance_id:
            by_play_request.setdefault(play_request_id, {})[event] = at
        if utterance_id:
            sample = by_utterance.setdefault(utterance_id, {"utterance_id": utterance_id})
            authoritative_final_acceptance = (
                record.get("authoritative") is True
                and str(record.get("kind") or "").strip().lower() == "final"
                and bool(str(record.get("source") or "").strip())
                and bool(str(record.get("lifecycle_role") or "").strip())
            )
            if event == "afplay_started":
                previous = _finite_float(sample.get(event))
                sample[event] = at if previous is None else min(previous, at)
            elif event != "accepted" or authoritative_final_acceptance:
                sample[event] = at
            if command_key is not None:
                sample["command_key"] = command_key
                sample["relay_command_seq"] = command_key[0]
                sample["relay_command_id"] = command_key[1]
            if play_request_id:
                sample["play_request_id"] = play_request_id
            if event == "afplay_started":
                playback_by_utterance.setdefault(utterance_id, []).append({
                    "authoritative": record.get("authoritative"),
                    "kind": str(record.get("kind") or "").strip().lower(),
                    "source": str(record.get("source") or "").strip().lower(),
                    "lifecycle_role": str(record.get("lifecycle_role") or "").strip().lower(),
                    "command_key": command_key,
                    "play_request_id": play_request_id,
                    "utterance_id": utterance_id,
                })
            if (
                event in {"started", "played"}
                and authoritative_final_acceptance
                and command_key is not None
            ):
                lifecycle = authoritative_lifecycle_counts.setdefault(
                    (command_key, utterance_id),
                    {"started": 0, "played": 0},
                )
                lifecycle[event] += 1

    samples: list[dict[str, Any]] = []
    stages = (
        "accepted",
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
        playback_records = playback_by_utterance.get(sample["utterance_id"], [])
        if not playback_records:
            continue
        playback = playback_records[0]
        if (
            any(
                record.get("authoritative") is not True
                or record.get("kind") != "final"
                or not record.get("source")
                or not record.get("lifecycle_role")
                or record.get("command_key") != command_key
                or record.get("play_request_id") != sample.get("play_request_id")
                for record in playback_records
            )
            or authoritative_playback_identities.get(command_key) != {
                (sample["utterance_id"], sample["play_request_id"])
            }
        ):
            continue
        if len(playback_records) > 1:
            lifecycle = authoritative_lifecycle_counts.get(
                (command_key, sample["utterance_id"]),
                {},
            )
            if lifecycle.get("started") != 1 or lifecycle.get("played") != 1:
                continue
        command = by_command.get(command_key, {})
        request = by_play_request.get(sample.get("play_request_id"), {})
        terminal_acknowledgements = acknowledgements.get(command_key, [])
        if len(terminal_acknowledgements) != 1:
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
        realization_trigger_event = (
            "option_detected"
            if timeline["option_detected"] is not None
            else "accepted"
        )
        timeline["realization_trigger"] = timeline[realization_trigger_event]
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
            "provider_ack_to_first_audio_ms": _delta(
                timeline,
                "provider_acknowledged",
                "afplay_started",
            ),
            "realization_trigger_to_first_audio_ms": _delta(
                timeline,
                "realization_trigger",
                "afplay_started",
            ),
            "option_to_first_audio_ms": _delta(timeline, "option_detected", "afplay_started"),
        }
        if durations["provider_ack_to_first_audio_ms"] is not None:
            samples.append({
                **sample,
                "authoritative": True,
                "kind": playback["kind"],
                "source": playback["source"],
                "lifecycle_role": playback["lifecycle_role"],
                "provider": terminal_acknowledgements[0]["provider"],
                "provider_acknowledged": timeline["provider_acknowledged"],
                "afplay_segment_count": len(playback_records),
                "realization_trigger": timeline["realization_trigger"],
                "realization_trigger_event": realization_trigger_event,
                # Backward-compatible diagnostic alias. This interval includes
                # provider generation and, in Queue mode, human waiting; it is
                # not the RR-325 playback-realization latency gate.
                "ack_to_first_audio_ms": durations["provider_ack_to_first_audio_ms"],
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
    provider_acknowledgement_to_audio = [
        sample["provider_ack_to_first_audio_ms"]
        for sample in samples
        if sample["provider_ack_to_first_audio_ms"] is not None
    ]
    realization_trigger_to_audio = [
        sample["realization_trigger_to_first_audio_ms"]
        for sample in samples
        if sample["realization_trigger_to_first_audio_ms"] is not None
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
        "realization_trigger_to_first_audio_p95_ms": _percentile(
            realization_trigger_to_audio,
            95,
        ),
        "provider_ack_to_first_audio_p95_ms": _percentile(
            provider_acknowledgement_to_audio,
            95,
        ),
        # Backward-compatible diagnostic alias; see the per-sample note above.
        "ack_to_first_audio_p95_ms": _percentile(
            provider_acknowledgement_to_audio,
            95,
        ),
        "samples": samples,
        "messenger_latency": build_messenger_latency_report(speech_records),
    }


def build_messenger_latency_report(
    speech_records: list[dict[str, Any]],
) -> dict[str, Any]:
    """Correlate the privacy-safe fast path from transcript to visible/audio output."""
    timelines: dict[tuple[int, str], dict[str, Any]] = {}
    for record in speech_records:
        command_key = _command_key(record)
        event = str(record.get("event") or "")
        at = _finite_float(record.get("at"))
        if command_key is None or at is None:
            continue
        if event not in {*MESSENGER_STAGES, "messenger_failed", "messenger_unavailable"}:
            continue
        source = str(record.get("source") or "").strip().lower()
        if event in {"tts_enqueued", "queued", "afplay_started"} and source not in {
            "messenger",
            "fallback",
        }:
            continue
        timeline = timelines.setdefault(command_key, {
            "relay_command_seq": command_key[0],
            "relay_command_id": command_key[1],
        })
        previous = _finite_float(timeline.get(event))
        timeline[event] = at if previous is None else min(previous, at)
        provider = str(record.get("provider") or "").strip().lower()
        if provider in {"codex", "claude"}:
            timeline["provider"] = provider
        if event in {"messenger_failed", "messenger_unavailable"}:
            timeline["failure_stage"] = event
            timeline["failure_outcome"] = str(record.get("outcome") or "unknown")
        if event in {"tts_enqueued", "queued", "afplay_started"}:
            timeline[f"{event}_source"] = source

    samples: list[dict[str, Any]] = []
    for timeline in timelines.values():
        received = _finite_float(timeline.get("user_turn_received"))
        if received is None:
            continue
        visible_event = "queued" if timeline.get("queued") is not None else "tts_enqueued"
        visible_at = _finite_float(timeline.get(visible_event))
        audio_at = _finite_float(timeline.get("afplay_started"))
        semantic_at = _finite_float(timeline.get("messenger_first_semantic_output"))
        semantic_healthy = semantic_at is not None and timeline.get("failure_stage") is None
        visible_ms = _milliseconds(received, visible_at)
        audio_ms = _milliseconds(received, audio_at)
        sample = {
            "relay_command_seq": timeline["relay_command_seq"],
            "relay_command_id": timeline["relay_command_id"],
            "provider": timeline.get("provider"),
            "semantic_output_ms": _milliseconds(received, semantic_at),
            "visible_response_ms": visible_ms,
            "audible_playback_ms": audio_ms,
            "visible_event": visible_event if visible_at is not None else None,
            "semantic_healthy": semantic_healthy,
            "visible_within_2s": bool(semantic_healthy and visible_ms is not None and visible_ms <= 2_000),
            "audible_within_3s": bool(semantic_healthy and audio_ms is not None and audio_ms <= 3_000),
            "bottleneck": _messenger_bottleneck(timeline),
        }
        if timeline.get("failure_stage"):
            sample["failure_stage"] = timeline["failure_stage"]
            sample["failure_outcome"] = timeline.get("failure_outcome")
        samples.append(sample)

    visible_passes = sum(bool(sample["visible_within_2s"]) for sample in samples)
    audio_passes = sum(bool(sample["audible_within_3s"]) for sample in samples)
    required_passes = math.ceil(len(samples) * 0.9) if samples else 0
    return {
        "sample_count": len(samples),
        "provider_sample_counts": {
            provider: sum(sample["provider"] == provider for sample in samples)
            for provider in ("codex", "claude")
        },
        "visible_within_2s_count": visible_passes,
        "audible_within_3s_count": audio_passes,
        "required_pass_count": required_passes,
        "installed_uat_passed": bool(
            len(samples) >= 10
            and visible_passes >= required_passes
            and audio_passes >= required_passes
        ),
        "samples": samples,
    }


def _milliseconds(started: float | None, ended: float | None) -> float | None:
    if started is None or ended is None or ended < started:
        return None
    return round((ended - started) * 1_000, 3)


def _messenger_bottleneck(timeline: dict[str, Any]) -> str:
    failure = str(timeline.get("failure_stage") or "")
    if failure:
        return failure
    for stage in MESSENGER_STAGES[1:]:
        if _finite_float(timeline.get(stage)) is None:
            return f"missing_{stage}"
    segments = (
        ("submission", "user_turn_received", "messenger_submitted"),
        ("provider_start", "messenger_submitted", "messenger_provider_started"),
        ("provider_generation", "messenger_provider_started", "messenger_first_semantic_output"),
        ("speech_enqueue", "messenger_first_semantic_output", "tts_enqueued"),
        ("visible_presentation", "tts_enqueued", "queued"),
        ("audio_playback", "queued", "afplay_started"),
    )
    durations = [
        (_milliseconds(_finite_float(timeline.get(start)), _finite_float(timeline.get(end))), label)
        for label, start, end in segments
    ]
    measured = [(duration, label) for duration, label in durations if duration is not None]
    return max(measured)[1] if measured else "unmeasured"


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
        print(
            "Realization trigger to first audio p95: "
            f"{report['realization_trigger_to_first_audio_p95_ms']} ms"
        )
        print(
            "Provider acknowledgement to first audio p95 (diagnostic): "
            f"{report['provider_ack_to_first_audio_p95_ms']} ms"
        )
        print(f"Option to first audio p95: {report['option_to_first_audio_p95_ms']} ms")
        messenger = report["messenger_latency"]
        print(
            "Messenger UAT: "
            f"{messenger['visible_within_2s_count']}/{messenger['sample_count']} visible, "
            f"{messenger['audible_within_3s_count']}/{messenger['sample_count']} audible, "
            f"passed={messenger['installed_uat_passed']}"
        )
        for sample in report["samples"]:
            print(json.dumps(sample, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
