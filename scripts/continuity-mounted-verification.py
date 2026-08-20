#!/usr/bin/env python3
"""Validate signed mounted continuity evidence without claiming audible playback."""

from __future__ import annotations

import argparse
import hashlib
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
REQUIRED_SCENARIO_EVENTS = (
    "speech_captured",
    "transcript_captured",
    "incident_classified",
    "continuity_agent_launched",
    "broker_result",
    "continuity_agent_completed",
    "continuity_resume",
    "command_accepted",
    "command_completed",
    "audible_playback_attested",
)
RECOVERY_EVENTS = frozenset({
    "incident_classified",
    "continuity_agent_launched",
    "broker_result",
    "continuity_agent_completed",
    "continuity_resume",
    "audible_playback_attested",
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


def _recovery_identity(record: dict[str, Any]) -> tuple[str, str, str, str] | None:
    values = tuple(
        str(record.get(field) or "").strip()
        for field in ("recovery_generation", "incident_id", "session_id", "command_id")
    )
    generation, incident_id, session_id, command_id = values
    if not all(values):
        return None
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", generation):
        return None
    if not re.fullmatch(r"inc-[0-9a-f]{12}", incident_id):
        return None
    if not re.fullmatch(r"session-[0-9a-f]{24}", session_id):
        return None
    if not re.fullmatch(r"command-[0-9a-f]{24}", command_id):
        return None
    return values


def _opaque_command_id(command_id: str) -> str:
    material = f"continuity-v1:command:{command_id}".encode("utf-8")
    return "command-" + hashlib.sha256(material).hexdigest()[:24]


def _broker_health(record: dict[str, Any]) -> tuple[str, str, str, float] | None:
    outcome = record.get("broker_outcome")
    if not isinstance(outcome, dict):
        return None
    health = outcome.get("health")
    if not isinstance(health, dict) or health.get("objective_restored") is not True:
        return None
    stable_for = health.get("stable_for_seconds")
    if isinstance(stable_for, bool):
        return None
    try:
        stable_for = float(stable_for)
    except (TypeError, ValueError):
        return None
    status = str(outcome.get("status") or "")
    capability = str(outcome.get("capability") or "")
    outcome_code = str(outcome.get("outcome_code") or "")
    evidence_codes = health.get("evidence_codes")
    if (
        status not in {"applied", "noop"}
        or stable_for < 60
        or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", capability)
        or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", outcome_code)
        or not isinstance(evidence_codes, list)
        or not evidence_codes
        or any(
            not isinstance(code, str)
            or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", code)
            for code in evidence_codes
        )
    ):
        return None
    return status, capability, outcome_code, stable_for


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
                for event in REQUIRED_SCENARIO_EVENTS
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
            recovery_identities = {
                _recovery_identity(item)
                for event in RECOVERY_EVENTS
                for item in event_records[event]
            }
            if len(recovery_identities) != 1 or None in recovery_identities:
                continue
            recovery_generation, incident_id, session_id, command_id = next(
                iter(recovery_identities)
            )
            if command_id != _opaque_command_id(command_key[1]):
                continue
            incident = event_records["incident_classified"][0]
            launch = event_records["continuity_agent_launched"][0]
            broker = event_records["broker_result"][0]
            completed = event_records["continuity_agent_completed"][0]
            handoff = event_records["continuity_resume"][0]
            audible = event_records["audible_playback_attested"][0]
            broker_health = _broker_health(broker)
            process_identity = str(launch.get("process_identity") or "")
            if (
                incident.get("classification") not in {"stalled", "recurring"}
                or incident.get("health") not in {"unavailable", "recovery_failed"}
                or not re.fullmatch(r"continuity-[0-9a-f]{32}", process_identity)
                or any(
                    item.get("process_identity") != process_identity
                    for item in (broker, completed)
                )
                or broker_health is None
                or completed.get("final_result") != "restored"
                or handoff.get("final_result") != "restored"
                or handoff.get("actor_role") != "canonical_bridge"
                or handoff.get("action") not in {"resume_exact", "reattach"}
                or audible.get("audible") is not True
                or audible.get("play_request_id") != sample["play_request_id"]
                or audible.get("utterance_id") != sample["utterance_id"]
            ):
                continue
            (
                broker_status,
                broker_capability,
                broker_outcome_code,
                stable_for_seconds,
            ) = broker_health
            valid = {
                "provider": provider,
                "scenario_id": scenario_id,
                "outcome": "transcript_captured",
                "classification": incident["classification"],
                "recovery_generation": recovery_generation,
                "incident_id": incident_id,
                "session_id": session_id,
                "command_id": command_id,
                "continuity_process_identity": process_identity,
                "broker_status": broker_status,
                "broker_capability": broker_capability,
                "broker_outcome_code": broker_outcome_code,
                "stable_health_seconds": stable_for_seconds,
                "continuity_resume_action": handoff["action"],
                "command_lifecycle_complete": True,
                "provider_acknowledged": True,
                "play_request_id": sample["play_request_id"],
                "utterance_id": sample["utterance_id"],
                "afplay_started": True,
                "audible_playback_attested": True,
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
