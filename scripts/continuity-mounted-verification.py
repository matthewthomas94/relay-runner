#!/usr/bin/env python3
"""Validate signed mounted continuity evidence without claiming audible playback."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SPEECH_REPORT = ROOT / "scripts" / "speech-latency-report.py"
SPEC = importlib.util.spec_from_file_location("speech_latency_report", SPEECH_REPORT)
speech_latency_report = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(speech_latency_report)


PROVIDERS = ("codex", "claude")
REQUIRED_TRANSCRIPT_EVENTS = frozenset({
    "speech_captured", "transcript_captured", "command_accepted", "command_completed",
})


def _signature_field(text: str, field: str) -> str | None:
    match = re.search(rf"^{re.escape(field)}=(.+)$", text, re.MULTILINE)
    return match.group(1).strip() if match else None


def inspect_signature(app_path: Path) -> dict[str, Any]:
    verified = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(app_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    details = subprocess.run(
        ["codesign", "-dv", "--verbose=4", str(app_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    text = details.stdout + details.stderr
    authority = _signature_field(text, "Authority")
    team = _signature_field(text, "TeamIdentifier")
    identifier = _signature_field(text, "Identifier")
    developer_id = bool(authority and authority.startswith("Developer ID Application"))
    return {
        "verified": verified.returncode == 0 and details.returncode == 0,
        "developer_id": developer_id,
        "team_identifier": team if team and team != "not set" else None,
        "bundle_identifier": identifier,
    }


def _key(record: dict[str, Any]) -> tuple[int, str] | None:
    try:
        sequence = record["relay_command_seq"]
        if isinstance(sequence, bool):
            return None
        command_id = str(record["relay_command_id"] or "").strip()
        return (int(sequence), command_id) if command_id else None
    except (KeyError, TypeError, ValueError):
        return None


def build_mounted_report(
    signature: dict[str, Any],
    continuity_records: list[dict[str, Any]],
    speech_records: list[dict[str, Any]],
    delivery_records: list[dict[str, Any]],
    *,
    physical_audio_attested: bool = False,
) -> dict[str, Any]:
    latency = speech_latency_report.build_report(speech_records, delivery_records)
    samples_by_key = {
        tuple(sample["command_key"]): sample for sample in latency["samples"]
    }
    scenarios: list[dict[str, Any]] = []
    blocker_codes: list[str] = []
    for provider in PROVIDERS:
        provider_records = [
            item for item in continuity_records
            if str(item.get("provider") or "").strip().lower() == provider
        ]
        by_scenario: dict[str, list[dict[str, Any]]] = {}
        for item in provider_records:
            scenario_id = str(item.get("scenario_id") or "").strip()
            if scenario_id:
                by_scenario.setdefault(scenario_id, []).append(item)
        valid = None
        for scenario_id, records in sorted(by_scenario.items()):
            event_records = {
                event: [item for item in records if str(item.get("event") or "") == event]
                for event in REQUIRED_TRANSCRIPT_EVENTS
            }
            event_keys = {event: {_key(item) for item in items} for event, items in event_records.items()}
            command_keys = set().union(*event_keys.values())
            if (
                len(command_keys) != 1
                or None in command_keys
                or any(len(items) != 1 for items in event_records.values())
                or any(keys != command_keys for keys in event_keys.values())
            ):
                continue
            command_key = next(iter(command_keys))
            sample = samples_by_key.get(command_key)
            if sample is None or sample.get("provider") != provider:
                continue
            valid = {
                "provider": provider,
                "scenario_id": scenario_id,
                "outcome": "transcript_captured",
                "command_lifecycle_complete": True,
                "provider_acknowledged": True,
                "play_request_id": sample["play_request_id"],
                "utterance_id": sample["utterance_id"],
                "afplay_started": True,
                "ack_to_first_audio_ms": sample["ack_to_first_audio_ms"],
            }
            break
        if valid is None:
            blocker_codes.append(f"provider_scenario_missing:{provider}")
        else:
            scenarios.append(valid)

    signature_passed = all((
        signature.get("verified"),
        signature.get("developer_id"),
        signature.get("team_identifier"),
        signature.get("bundle_identifier"),
    ))
    if not signature_passed:
        blocker_codes.append("developer_id_signature_missing")
    mounted_passed = signature_passed and len(scenarios) == len(PROVIDERS)
    if not physical_audio_attested:
        blocker_codes.append("physical_audio_attestation_missing")
    return {
        "schema_version": 1,
        "status": "passed" if mounted_passed and physical_audio_attested else "verification_blocked",
        "automated_source_evidence": "not_part_of_mounted_gate",
        "mounted_app_evidence": {
            "status": "passed" if mounted_passed else "blocked",
            "signature": signature,
            "provider_scenarios": scenarios,
            "provider_sample_counts": latency["provider_sample_counts"],
            "ack_to_first_audio_p95_ms": latency["ack_to_first_audio_p95_ms"],
        },
        "physical_audio_evidence": {
            "status": "passed" if physical_audio_attested else "blocked",
            "note": (
                "Human attested audible playback."
                if physical_audio_attested
                else "afplay_started is process evidence and does not prove audible output."
            ),
        },
        "blocker_codes": blocker_codes,
    }


def _records(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--continuity-log", required=True)
    parser.add_argument("--speech-log", required=True)
    parser.add_argument("--delivery-log", required=True)
    parser.add_argument("--physical-audio-attested", action="store_true")
    args = parser.parse_args()
    report = build_mounted_report(
        inspect_signature(Path(args.app)),
        _records(Path(args.continuity_log)),
        _records(Path(args.speech_log)),
        _records(Path(args.delivery_log)),
        physical_audio_attested=args.physical_audio_attested,
    )
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["status"] == "passed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
