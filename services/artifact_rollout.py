#!/usr/bin/env python3
"""Evidence-gated rollout policy for project-owned Relay artifacts.

The rollout store is intentionally separate from the project registry and the
project's artifact ref.  It decides whether a cohort may *start* new work; it
never deletes or rewrites a repository, ref, migration journal, or evidence
record.  Source-test success is recordable evidence, but cohort promotion is a
separate confirmed operator action and later cohorts require signed installed
evidence.
"""

from __future__ import annotations

import contextlib
import dataclasses
import fcntl
import hashlib
import json
import os
import re
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Sequence


ROLLOUT_SCHEMA_VERSION = 1
PROJECT_OPT_IN = "project_opt_in"
NEW_PROJECT_DEFAULT = "new_project_default"
LEGACY_MIGRATION_OFFER = "legacy_migration_offer"
COHORTS = (PROJECT_OPT_IN, NEW_PROJECT_DEFAULT, LEGACY_MIGRATION_OFFER)

EVIDENCE_KINDS = frozenset(
    {
        "source_matrix",
        "two_device_remote",
        "failure_injection",
        "signed_installed_workspace",
        "installed_provider_parity",
        "fresh_install_reset",
        "migration_rollback",
        "operator_recovery",
        "opt_in_cohort_accepted",
        "new_project_cohort_accepted",
    }
)

NEW_PROJECT_REQUIRED_EVIDENCE = frozenset(
    {
        "source_matrix",
        "two_device_remote",
        "failure_injection",
        "signed_installed_workspace",
        "installed_provider_parity",
        "fresh_install_reset",
        "operator_recovery",
        "opt_in_cohort_accepted",
    }
)
LEGACY_REQUIRED_EVIDENCE = NEW_PROJECT_REQUIRED_EVIDENCE | {
    "migration_rollback",
    "new_project_cohort_accepted",
}

_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
_SAFE_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.+-]{0,63}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_SCENARIO_ID = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
_FORBIDDEN_DIAGNOSTIC_KEYS = frozenset(
    {
        "audio",
        "conversation",
        "hidden_reasoning",
        "log",
        "logs",
        "prompt",
        "raw_log",
        "raw_transcript",
        "reasoning",
        "secret",
        "token",
        "tool_output",
        "trace",
        "transcript",
    }
)
_EVIDENCE_KEYS = frozenset(
    {
        "evidence_id",
        "kind",
        "outcome",
        "recorded_at",
        "report_sha256",
        "build_version",
        "build_number",
        "bundle_sha256",
        "signer_team_id",
        "providers",
        "scenario_ids",
        "rejection_code",
    }
)
_DOCUMENT_KEYS = frozenset(
    {
        "schema_version",
        "revision",
        "last_event",
        "updated_at",
        "cohorts",
        "project_opt_ins",
        "evidence",
    }
)
_COHORT_KEYS = frozenset(
    {
        "enabled",
        "paused",
        "writes_allowed",
        "sync_allowed",
        "pause_reason_code",
        "updated_at",
    }
)
_PROJECT_OPT_IN_KEYS = frozenset({"enabled", "updated_at"})


class ArtifactRolloutError(RuntimeError):
    """Base rollout error with a stable recovery code and public action."""

    def __init__(self, message: str, *, code: str, recovery: str):
        super().__init__(message)
        self.code = code
        self.recovery = recovery


class ArtifactRolloutBlocked(ArtifactRolloutError):
    pass


@dataclasses.dataclass(frozen=True)
class RolloutEvidence:
    evidence_id: str
    kind: str
    outcome: str
    recorded_at: str
    report_sha256: str
    build_version: str | None = None
    build_number: str | None = None
    bundle_sha256: str | None = None
    signer_team_id: str | None = None
    providers: tuple[str, ...] = ()
    scenario_ids: tuple[str, ...] = ()
    rejection_code: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


@dataclasses.dataclass(frozen=True)
class RolloutDecision:
    project_id: str
    cohort: str | None
    artifact_writes_enabled: bool
    artifact_sync_enabled: bool
    offer_legacy_migration: bool
    reason_code: str


class ArtifactRolloutStore:
    """Atomic local policy store with fail-closed staged cohort transitions."""

    def __init__(
        self,
        state_root: str | os.PathLike[str],
        *,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.state_root = Path(state_root).expanduser().resolve()
        self.rollout_root = self.state_root / "rollout"
        self.path = self.rollout_root / "artifact-rollout-v1.json"
        self.backup_path = self.rollout_root / "artifact-rollout-v1.backup.json"
        self.lock_path = self.rollout_root / "artifact-rollout-v1.lock"
        self.now = now or (lambda: datetime.now(UTC))

    def load(self) -> dict[str, Any]:
        """Load current policy; corruption fails closed unless backup is valid."""
        if not self.path.exists():
            return self._default_document()
        try:
            return self._read_document(self.path)
        except ArtifactRolloutError as primary_error:
            if self.backup_path.exists():
                try:
                    recovered = self._read_document(self.backup_path)
                    recovered["recovery_state"] = "primary_corrupt_using_backup"
                    return recovered
                except ArtifactRolloutError:
                    pass
            raise ArtifactRolloutBlocked(
                "Artifact rollout policy and backup are unreadable; all new artifact starts are blocked.",
                code="rollout_state_corrupt",
                recovery=(
                    "Stop artifact writers, restore a reviewed rollout backup, then explicitly resume the intended cohort."
                ),
            ) from primary_error

    def record_evidence(self, evidence: RolloutEvidence) -> dict[str, Any]:
        validated = self._validate_evidence(evidence)
        with self._locked_document() as document:
            existing = next(
                (
                    item
                    for item in document["evidence"]
                    if item.get("evidence_id") == validated.evidence_id
                ),
                None,
            )
            payload = validated.as_dict()
            payload["providers"] = list(validated.providers)
            payload["scenario_ids"] = list(validated.scenario_ids)
            if existing is not None:
                if existing != payload:
                    raise ArtifactRolloutBlocked(
                        f"Evidence ID {validated.evidence_id!r} already has different content.",
                        code="evidence_id_collision",
                        recovery="Use a new immutable evidence ID after reviewing both records.",
                    )
                return self.diagnostics(document=document)
            document["evidence"].append(payload)
            self._advance(document, event="evidence_recorded")
        return self.diagnostics()

    def set_project_opt_in(
        self,
        project_id: str,
        *,
        enabled: bool,
        confirmed: bool,
        writers_drained: bool = False,
        sync_frozen: bool = False,
    ) -> RolloutDecision:
        self._validate_id(project_id, "project ID")
        if not confirmed:
            raise ArtifactRolloutBlocked(
                "Per-project artifact rollout requires explicit confirmation.",
                code="project_confirmation_required",
                recovery="Review the project identity and rollback boundary, then confirm the opt-in change.",
            )
        with self._locked_document() as document:
            cohort = document["cohorts"][PROJECT_OPT_IN]
            if enabled and (cohort["paused"] or not cohort["writes_allowed"]):
                raise ArtifactRolloutBlocked(
                    "The per-project cohort kill switch currently blocks new artifact writes.",
                    code="project_opt_in_paused",
                    recovery="Resolve the recorded cohort failure before an explicit operator resume.",
                )
            current = document["project_opt_ins"].get(project_id)
            if not enabled and current and (not writers_drained or not sync_frozen):
                raise ArtifactRolloutBlocked(
                    "Disabling a project requires drained writers and frozen synchronization.",
                    code="project_not_drained",
                    recovery="Drain or safely freeze active work and sync, then retry the rollback.",
                )
            document["project_opt_ins"][project_id] = {
                "enabled": enabled,
                "updated_at": self._timestamp(),
            }
            self._advance(document, event="project_opt_in_changed")
        return self.decision(project_id, project_kind="existing")

    def promote_cohort(self, cohort: str, *, confirmed: bool) -> dict[str, Any]:
        self._validate_cohort(cohort)
        if cohort == PROJECT_OPT_IN:
            raise ArtifactRolloutBlocked(
                "The per-project opt-in cohort is the baseline and projects remain individually off.",
                code="baseline_cohort",
                recovery="Use an explicit per-project opt-in; do not replace it with a global default.",
            )
        if not confirmed:
            raise ArtifactRolloutBlocked(
                f"Promoting {cohort} requires an explicit operator confirmation.",
                code="cohort_confirmation_required",
                recovery="Review accepted evidence and recovery documentation, then confirm promotion.",
            )
        with self._locked_document() as document:
            missing = self._missing_evidence(document, cohort)
            if missing:
                raise ArtifactRolloutBlocked(
                    f"Cohort {cohort} is missing accepted evidence: {', '.join(missing)}.",
                    code="cohort_evidence_incomplete",
                    recovery="Record accepted external evidence for every listed kind; source tests alone are insufficient.",
                )
            state = document["cohorts"][cohort]
            state.update(
                {
                    "enabled": True,
                    "paused": False,
                    "writes_allowed": True,
                    "sync_allowed": True,
                    "updated_at": self._timestamp(),
                }
            )
            self._advance(document, event="cohort_promoted")
        return self.diagnostics()

    def pause_cohort(
        self,
        cohort: str,
        *,
        writers_drained: bool,
        sync_frozen: bool,
        reason_code: str,
    ) -> dict[str, Any]:
        self._validate_cohort(cohort)
        self._validate_id(reason_code, "reason code")
        if not writers_drained or not sync_frozen:
            raise ArtifactRolloutBlocked(
                "A cohort kill switch requires drained writers and safely frozen synchronization.",
                code="cohort_not_drained",
                recovery="Drain or freeze active work without deleting refs/history, then retry the kill switch.",
            )
        with self._locked_document() as document:
            state = document["cohorts"][cohort]
            state.update(
                {
                    "paused": True,
                    "writes_allowed": False,
                    "sync_allowed": False,
                    "pause_reason_code": reason_code,
                    "updated_at": self._timestamp(),
                }
            )
            self._advance(document, event="cohort_paused")
        return self.diagnostics()

    def resume_cohort(self, cohort: str, *, confirmed: bool) -> dict[str, Any]:
        self._validate_cohort(cohort)
        if not confirmed:
            raise ArtifactRolloutBlocked(
                "Resuming a rollout cohort requires explicit confirmation.",
                code="cohort_confirmation_required",
                recovery="Review the failure and preserved refs/history before resuming.",
            )
        with self._locked_document() as document:
            state = document["cohorts"][cohort]
            if cohort != PROJECT_OPT_IN and not state["enabled"]:
                raise ArtifactRolloutBlocked(
                    f"Cohort {cohort} has not been promoted.",
                    code="cohort_not_promoted",
                    recovery="Satisfy its evidence gate and explicitly promote it first.",
                )
            missing = self._missing_evidence(document, cohort)
            if cohort != PROJECT_OPT_IN and missing:
                raise ArtifactRolloutBlocked(
                    f"Cohort {cohort} no longer has accepted evidence: {', '.join(missing)}.",
                    code="cohort_evidence_incomplete",
                    recovery="Resolve the rejected evidence and record a new immutable acceptance record.",
                )
            state.update(
                {
                    "paused": False,
                    "writes_allowed": True,
                    "sync_allowed": True,
                    "pause_reason_code": None,
                    "updated_at": self._timestamp(),
                }
            )
            self._advance(document, event="cohort_resumed")
        return self.diagnostics()

    def decision(self, project_id: str, *, project_kind: str) -> RolloutDecision:
        self._validate_id(project_id, "project ID")
        if project_kind not in {"existing", "new", "legacy"}:
            raise ArtifactRolloutError(
                f"Unsupported project kind: {project_kind!r}",
                code="invalid_project_kind",
                recovery="Use existing, new, or legacy after confirming registry identity.",
            )
        document = self.load()
        explicit = document["project_opt_ins"].get(project_id, {}).get("enabled") is True
        if explicit:
            state = document["cohorts"][PROJECT_OPT_IN]
            enabled = not state["paused"] and state["writes_allowed"]
            return RolloutDecision(
                project_id=project_id,
                cohort=PROJECT_OPT_IN,
                artifact_writes_enabled=enabled,
                artifact_sync_enabled=enabled and state["sync_allowed"],
                offer_legacy_migration=False,
                reason_code="explicit_project_opt_in" if enabled else "project_opt_in_kill_switch",
            )
        if project_kind == "new":
            state = document["cohorts"][NEW_PROJECT_DEFAULT]
            enabled = state["enabled"] and not state["paused"] and state["writes_allowed"]
            return RolloutDecision(
                project_id=project_id,
                cohort=NEW_PROJECT_DEFAULT if state["enabled"] else None,
                artifact_writes_enabled=enabled,
                artifact_sync_enabled=enabled and state["sync_allowed"],
                offer_legacy_migration=False,
                reason_code="new_project_default" if enabled else "new_project_default_gated",
            )
        if project_kind == "legacy":
            state = document["cohorts"][LEGACY_MIGRATION_OFFER]
            offer = state["enabled"] and not state["paused"]
            return RolloutDecision(
                project_id=project_id,
                cohort=LEGACY_MIGRATION_OFFER if state["enabled"] else None,
                artifact_writes_enabled=False,
                artifact_sync_enabled=False,
                offer_legacy_migration=offer,
                reason_code="legacy_migration_offered" if offer else "legacy_migration_gated",
            )
        return RolloutDecision(
            project_id=project_id,
            cohort=None,
            artifact_writes_enabled=False,
            artifact_sync_enabled=False,
            offer_legacy_migration=False,
            reason_code="project_default_off",
        )

    def diagnostics(self, *, document: Mapping[str, Any] | None = None) -> dict[str, Any]:
        """Return bounded, privacy-safe rollout diagnostics only."""
        current = dict(document or self.load())
        latest = self._latest_evidence(current)
        cohorts = {}
        for name in COHORTS:
            state = current["cohorts"][name]
            missing = self._missing_evidence(current, name)
            cohorts[name] = {
                "enabled": bool(state["enabled"]),
                "paused": bool(state["paused"]),
                "writes_allowed": bool(state["writes_allowed"]),
                "sync_allowed": bool(state["sync_allowed"]),
                "missing_evidence": missing,
                "pause_reason_code": state.get("pause_reason_code"),
            }
        return {
            "schema_version": ROLLOUT_SCHEMA_VERSION,
            "revision": int(current["revision"]),
            "last_event": current.get("last_event"),
            "recovery_state": current.get("recovery_state", "normal"),
            "cohorts": cohorts,
            "project_opt_in_count": sum(
                1 for value in current["project_opt_ins"].values() if value.get("enabled") is True
            ),
            "evidence": {
                kind: {
                    "outcome": item["outcome"],
                    "report_sha256": item["report_sha256"],
                    "bundle_sha256": item.get("bundle_sha256"),
                    "providers": list(item.get("providers") or []),
                    "scenario_count": len(item.get("scenario_ids") or []),
                    "rejection_code": item.get("rejection_code"),
                }
                for kind, item in sorted(latest.items())
            },
        }

    # ------------------------------------------------------------------
    # Validation and persistence
    # ------------------------------------------------------------------

    def _default_document(self) -> dict[str, Any]:
        timestamp = self._timestamp()
        return {
            "schema_version": ROLLOUT_SCHEMA_VERSION,
            "revision": 0,
            "last_event": "initialized_default_off",
            "updated_at": timestamp,
            "cohorts": {
                PROJECT_OPT_IN: {
                    "enabled": True,
                    "paused": False,
                    "writes_allowed": True,
                    "sync_allowed": True,
                    "pause_reason_code": None,
                    "updated_at": timestamp,
                },
                NEW_PROJECT_DEFAULT: {
                    "enabled": False,
                    "paused": False,
                    "writes_allowed": False,
                    "sync_allowed": False,
                    "pause_reason_code": None,
                    "updated_at": timestamp,
                },
                LEGACY_MIGRATION_OFFER: {
                    "enabled": False,
                    "paused": False,
                    "writes_allowed": False,
                    "sync_allowed": False,
                    "pause_reason_code": None,
                    "updated_at": timestamp,
                },
            },
            "project_opt_ins": {},
            "evidence": [],
        }

    def _read_document(self, path: Path) -> dict[str, Any]:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ArtifactRolloutError(
                f"Invalid rollout state at {path.name}: {error}",
                code="invalid_rollout_state",
                recovery="Restore a reviewed backup while artifact writers are stopped.",
            ) from error
        self._validate_document(value)
        return value

    def _validate_document(self, value: Any) -> None:
        if (
            not isinstance(value, dict)
            or set(value) != _DOCUMENT_KEYS
            or value.get("schema_version") != ROLLOUT_SCHEMA_VERSION
        ):
            raise ArtifactRolloutError(
                "Unsupported artifact rollout state schema.",
                code="invalid_rollout_schema",
                recovery="Upgrade Relay Runner or restore a compatible reviewed backup.",
            )
        if not isinstance(value.get("revision"), int) or value["revision"] < 0:
            raise ArtifactRolloutError(
                "Artifact rollout revision is invalid.",
                code="invalid_rollout_revision",
                recovery="Restore a reviewed backup while writers are stopped.",
            )
        cohorts = value.get("cohorts")
        if not isinstance(cohorts, dict) or set(cohorts) != set(COHORTS):
            raise ArtifactRolloutError(
                "Artifact rollout cohorts are incomplete.",
                code="invalid_rollout_cohorts",
                recovery="Restore a reviewed schema-1 rollout document.",
            )
        for name, state in cohorts.items():
            if not isinstance(state, dict) or set(state) != _COHORT_KEYS:
                raise ArtifactRolloutError(
                    f"Rollout cohort {name} is invalid.",
                    code="invalid_rollout_cohort",
                    recovery="Restore a reviewed rollout document.",
                )
            for key in ("enabled", "paused", "writes_allowed", "sync_allowed"):
                if not isinstance(state.get(key), bool):
                    raise ArtifactRolloutError(
                        f"Rollout cohort {name} has invalid {key}.",
                        code="invalid_rollout_cohort",
                        recovery="Restore a reviewed rollout document.",
                    )
        projects = value.get("project_opt_ins")
        if not isinstance(projects, dict):
            raise ArtifactRolloutError(
                "Per-project opt-in state is invalid.",
                code="invalid_project_opt_ins",
                recovery="Restore a reviewed rollout document.",
            )
        for project_id, state in projects.items():
            self._validate_id(project_id, "project ID")
            if (
                not isinstance(state, dict)
                or set(state) != _PROJECT_OPT_IN_KEYS
                or not isinstance(state.get("enabled"), bool)
            ):
                raise ArtifactRolloutError(
                    f"Per-project opt-in state is invalid for {project_id!r}.",
                    code="invalid_project_opt_ins",
                    recovery="Restore a reviewed rollout document.",
                )
        evidence = value.get("evidence")
        if not isinstance(evidence, list):
            raise ArtifactRolloutError(
                "Rollout evidence list is invalid.",
                code="invalid_rollout_evidence",
                recovery="Restore a reviewed rollout document.",
            )
        seen = set()
        for raw in evidence:
            if not isinstance(raw, dict) or set(raw) != _EVIDENCE_KEYS:
                raise ArtifactRolloutError(
                    "Rollout evidence entry has an unsupported or missing field.",
                    code="invalid_rollout_evidence",
                    recovery="Restore a reviewed rollout document.",
                )
            parsed = self._validate_evidence(RolloutEvidence(
                evidence_id=raw.get("evidence_id"),
                kind=raw.get("kind"),
                outcome=raw.get("outcome"),
                recorded_at=raw.get("recorded_at"),
                report_sha256=raw.get("report_sha256"),
                build_version=raw.get("build_version"),
                build_number=raw.get("build_number"),
                bundle_sha256=raw.get("bundle_sha256"),
                signer_team_id=raw.get("signer_team_id"),
                providers=tuple(raw.get("providers") or ()),
                scenario_ids=tuple(raw.get("scenario_ids") or ()),
                rejection_code=raw.get("rejection_code"),
            ))
            if parsed.evidence_id in seen:
                raise ArtifactRolloutError(
                    "Rollout evidence IDs are not unique.",
                    code="duplicate_rollout_evidence",
                    recovery="Restore a reviewed rollout document and reconcile immutable evidence IDs.",
                )
            seen.add(parsed.evidence_id)

    def _validate_evidence(self, evidence: RolloutEvidence) -> RolloutEvidence:
        self._validate_id(evidence.evidence_id, "evidence ID")
        if evidence.kind not in EVIDENCE_KINDS:
            raise ArtifactRolloutError(
                f"Unsupported rollout evidence kind: {evidence.kind!r}",
                code="invalid_evidence_kind",
                recovery="Use a documented bounded evidence kind.",
            )
        if evidence.outcome not in {"accepted", "rejected"}:
            raise ArtifactRolloutError(
                "Rollout evidence outcome must be accepted or rejected.",
                code="invalid_evidence_outcome",
                recovery="Record the external review result explicitly.",
            )
        try:
            parsed_at = datetime.fromisoformat(evidence.recorded_at.replace("Z", "+00:00"))
        except (AttributeError, ValueError) as error:
            raise ArtifactRolloutError(
                "Rollout evidence timestamp must be ISO-8601.",
                code="invalid_evidence_timestamp",
                recovery="Record a UTC evidence timestamp.",
            ) from error
        if parsed_at.tzinfo is None:
            raise ArtifactRolloutError(
                "Rollout evidence timestamp must include a timezone.",
                code="invalid_evidence_timestamp",
                recovery="Record a UTC evidence timestamp.",
            )
        self._validate_sha(evidence.report_sha256, "report SHA-256")
        if evidence.bundle_sha256 is not None:
            self._validate_sha(evidence.bundle_sha256, "bundle SHA-256")
        for value, label in (
            (evidence.build_version, "build version"),
            (evidence.build_number, "build number"),
            (evidence.signer_team_id, "signer team ID"),
            (evidence.rejection_code, "rejection code"),
        ):
            if value is not None and not _SAFE_VERSION.fullmatch(value):
                raise ArtifactRolloutError(
                    f"Rollout evidence {label} is not a bounded identifier.",
                    code="unsafe_evidence_field",
                    recovery="Use an identifier only; keep paths, logs, transcripts, and free-form text outside diagnostics.",
                )
        providers = tuple(sorted(set(evidence.providers)))
        if any(provider not in {"codex", "claude"} for provider in providers):
            raise ArtifactRolloutError(
                "Rollout provider evidence is invalid.",
                code="invalid_evidence_provider",
                recovery="Use only codex and claude provider identifiers.",
            )
        scenarios = tuple(sorted(set(evidence.scenario_ids)))
        if len(scenarios) > 128 or any(not _SCENARIO_ID.fullmatch(item) for item in scenarios):
            raise ArtifactRolloutError(
                "Rollout scenario evidence contains an unsafe or unbounded identifier.",
                code="unsafe_evidence_scenarios",
                recovery="Use at most 128 documented lowercase scenario IDs.",
            )
        if evidence.outcome == "rejected" and evidence.rejection_code is None:
            raise ArtifactRolloutError(
                "Rejected evidence requires a stable rejection code.",
                code="missing_rejection_code",
                recovery="Record a bounded reason code; keep detailed recovery in the verification report.",
            )
        if evidence.kind in {"signed_installed_workspace", "installed_provider_parity"}:
            if not evidence.bundle_sha256 or not evidence.signer_team_id:
                raise ArtifactRolloutError(
                    "Installed evidence requires signed bundle identity.",
                    code="missing_signed_bundle_identity",
                    recovery="Verify the Developer ID signed installed app and record its bundle hash and team ID.",
                )
        if evidence.kind == "installed_provider_parity" and set(providers) != {"codex", "claude"}:
            raise ArtifactRolloutError(
                "Installed provider parity evidence must cover Codex and Claude.",
                code="provider_parity_incomplete",
                recovery="Run the same installed scope/lifecycle scenarios with both providers.",
            )
        return dataclasses.replace(evidence, providers=providers, scenario_ids=scenarios)

    def _latest_evidence(self, document: Mapping[str, Any]) -> dict[str, Mapping[str, Any]]:
        latest: dict[str, Mapping[str, Any]] = {}
        for item in document["evidence"]:
            latest[str(item["kind"])] = item
        return latest

    def _missing_evidence(self, document: Mapping[str, Any], cohort: str) -> list[str]:
        if cohort == PROJECT_OPT_IN:
            return []
        required = (
            NEW_PROJECT_REQUIRED_EVIDENCE
            if cohort == NEW_PROJECT_DEFAULT
            else LEGACY_REQUIRED_EVIDENCE
        )
        latest = self._latest_evidence(document)
        return sorted(
            kind
            for kind in required
            if kind not in latest or latest[kind].get("outcome") != "accepted"
        )

    @contextlib.contextmanager
    def _locked_document(self) -> Iterator[dict[str, Any]]:
        self.rollout_root.mkdir(parents=True, exist_ok=True)
        with self.lock_path.open("a+b") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            document = self.load()
            # Never persist the transient load diagnostic marker.
            document.pop("recovery_state", None)
            before = json.dumps(document, sort_keys=True, separators=(",", ":"))
            try:
                yield document
                self._validate_document(document)
                after = json.dumps(document, sort_keys=True, separators=(",", ":"))
                if after != before:
                    self._write_atomic(document)
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    def _write_atomic(self, document: Mapping[str, Any]) -> None:
        payload = (json.dumps(document, sort_keys=True, indent=2) + "\n").encode("utf-8")
        if self.path.exists():
            try:
                self._read_document(self.path)
            except ArtifactRolloutError:
                # A valid backup is the recovery authority.  Never replace it
                # with corrupt primary bytes while repairing the primary.
                pass
            else:
                self._replace_file(self.backup_path, self.path.read_bytes())
        self._replace_file(self.path, payload)

    def _replace_file(self, destination: Path, payload: bytes) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{destination.name}.",
            dir=destination.parent,
        )
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, destination)
            directory_fd = os.open(destination.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            with contextlib.suppress(FileNotFoundError):
                temporary.unlink()

    def _advance(self, document: dict[str, Any], *, event: str) -> None:
        document["revision"] += 1
        document["last_event"] = event
        document["updated_at"] = self._timestamp()

    def _timestamp(self) -> str:
        return self.now().astimezone(UTC).isoformat().replace("+00:00", "Z")

    @staticmethod
    def _validate_id(value: Any, label: str) -> None:
        if not isinstance(value, str) or not _SAFE_ID.fullmatch(value):
            raise ArtifactRolloutError(
                f"Invalid {label}: {value!r}",
                code="invalid_identifier",
                recovery="Use a bounded alphanumeric identifier after confirming project identity.",
            )

    @staticmethod
    def _validate_sha(value: Any, label: str) -> None:
        if not isinstance(value, str) or not _SHA256.fullmatch(value):
            raise ArtifactRolloutError(
                f"Invalid {label}.",
                code="invalid_evidence_hash",
                recovery="Hash the reviewed evidence bytes with SHA-256 and record the lowercase digest.",
            )

    @staticmethod
    def _validate_cohort(cohort: str) -> None:
        if cohort not in COHORTS:
            raise ArtifactRolloutError(
                f"Unknown artifact rollout cohort: {cohort!r}",
                code="invalid_cohort",
                recovery=f"Use one of: {', '.join(COHORTS)}.",
            )


def privacy_safe_report_digest(report: Mapping[str, Any]) -> str:
    """Digest a bounded report only after refusing prohibited diagnostic keys."""

    def inspect(value: Any) -> None:
        if isinstance(value, Mapping):
            for key, child in value.items():
                normalized = str(key).lower()
                if normalized in _FORBIDDEN_DIAGNOSTIC_KEYS:
                    raise ArtifactRolloutError(
                        f"Verification report contains prohibited diagnostic field: {key}",
                        code="prohibited_diagnostic_field",
                        recovery="Replace raw/private content with bounded counts, states, IDs, and hashes.",
                    )
                inspect(child)
        elif isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
            for child in value:
                inspect(child)
        elif isinstance(value, str) and len(value.encode("utf-8")) > 4096:
            raise ArtifactRolloutError(
                "Verification report contains an unbounded string.",
                code="unbounded_diagnostic_field",
                recovery="Store the detailed evidence separately and report only its hash and stable outcome code.",
            )

    inspect(report)
    payload = json.dumps(report, sort_keys=True, separators=(",", ":")).encode("utf-8")
    if len(payload) > 256 * 1024:
        raise ArtifactRolloutError(
            "Verification report exceeds the 256 KiB diagnostic limit.",
            code="diagnostic_report_too_large",
            recovery="Keep bounded outcomes and hashes only.",
        )
    return hashlib.sha256(payload).hexdigest()
